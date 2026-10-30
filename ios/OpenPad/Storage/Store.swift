import Foundation
import OpenPadCore
import UIKit

/// What the library shows about a notebook without loading its ink.
struct NotebookEntry: Codable, Identifiable, Equatable {
    var id: String
    var title: String
    var folder = ""
    var sections = 1
    var pages = 1
    var cover: String?  // first page, for the card's thumbnail
    var modified: Int64 = 0
    var lastOpened: Int64 = 0
    var bytes = 0  // on this iPad: the notebook plus the files only it uses
    var dirty = true  // changed since the last sync
    var synced: String?  // digest the computer last confirmed
    var filesSynced = false  // the computer has every file its pages show
    var offloaded = false  // only its outline and thumbnails are on this iPad
    var keep = false  // never offload
    var deleted: Int64?  // deleted here; the computer still has to hear about it

    init(id: String, title: String) {
        self.id = id
        self.title = title
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        folder = try c.decodeIfPresent(String.self, forKey: .folder) ?? ""
        sections = try c.decodeIfPresent(Int.self, forKey: .sections) ?? 1
        pages = try c.decodeIfPresent(Int.self, forKey: .pages) ?? 1
        cover = try c.decodeIfPresent(String.self, forKey: .cover)
        modified = try c.decodeIfPresent(Int64.self, forKey: .modified) ?? 0
        lastOpened = try c.decodeIfPresent(Int64.self, forKey: .lastOpened) ?? 0
        bytes = try c.decodeIfPresent(Int.self, forKey: .bytes) ?? 0
        dirty = try c.decodeIfPresent(Bool.self, forKey: .dirty) ?? true
        synced = try c.decodeIfPresent(String.self, forKey: .synced)
        filesSynced = try c.decodeIfPresent(Bool.self, forKey: .filesSynced) ?? false
        offloaded = try c.decodeIfPresent(Bool.self, forKey: .offloaded) ?? false
        keep = try c.decodeIfPresent(Bool.self, forKey: .keep) ?? false
        deleted = try c.decodeIfPresent(Int64.self, forKey: .deleted)
    }

    /// Safe to remove from this iPad: the computer has exactly this copy.
    func canOffload(digest: String) -> Bool {
        !offloaded && !keep && !dirty && filesSynced && synced == digest && deleted == nil
    }
}

/// The computer this iPad is connected to.
struct SavedLink: Codable, Equatable {
    var base: String
    var key: String
    var name: String
    var alts: [String]
}

/// Notebooks on this iPad, in Application Support/OpenPad:
///   notebooks/<id>.json   one notebook (layout, pages, ink); an outline only when offloaded
///   assets/<sha256>       PDFs and images pages show
///   thumbs/<page>.jpg     page thumbnails (kept when a notebook is offloaded)
///   index.json            library entries and sync bookkeeping
///   folders.json          folders made here that have no notebooks yet
///   link.json             the connected computer
@MainActor
final class Store {
    let root: URL
    private(set) var index: [String: NotebookEntry] = [:]
    private(set) var extraFolders: [String] = []
    private var thumbKeys: [String: String] = [:]
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let protection: Data.WritingOptions = [.atomic, .completeFileProtectionUntilFirstUserAuthentication]

    nonisolated static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenPad", isDirectory: true)
    }

    init(root: URL? = nil) {
        let base = root ?? Self.defaultRoot
        self.root = base
        for dir in ["notebooks", "assets", "thumbs"] {
            try? FileManager.default.createDirectory(at: base.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        if let data = try? Data(contentsOf: base.appendingPathComponent("index.json")),
           let list = try? decoder.decode([NotebookEntry].self, from: data) {
            index = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        }
        if let data = try? Data(contentsOf: base.appendingPathComponent("folders.json")),
           let list = try? decoder.decode([String].self, from: data) {
            extraFolders = list
        }
        if let data = try? Data(contentsOf: base.appendingPathComponent("thumbs/index.json")),
           let keys = try? decoder.decode([String: String].self, from: data) {
            thumbKeys = keys
        }
    }

    private func notebookURL(_ id: String) -> URL { root.appendingPathComponent("notebooks/\(id).json") }
    func assetURL(_ sha: String) -> URL { root.appendingPathComponent("assets/\(sha)") }
    private func thumbURL(_ page: String) -> URL { root.appendingPathComponent("thumbs/\(page).jpg") }

    private func writeIndex() {
        let list = index.values.sorted { $0.id < $1.id }
        if let data = try? encoder.encode(list) { try? data.write(to: root.appendingPathComponent("index.json"), options: protection) }
    }

    // MARK: notebooks

    var library: [NotebookEntry] {
        index.values.filter { $0.deleted == nil }.sorted { $0.modified > $1.modified }
    }

    /// The notebook (an outline only, if offloaded: check the entry).
    func load(_ id: String) -> Notebook? {
        guard index[id]?.deleted == nil, let data = try? Data(contentsOf: notebookURL(id)) else { return nil }
        return try? decoder.decode(Notebook.self, from: data)
    }

    /// Save a full notebook. `dirty` marks it for the next sync.
    func save(_ nb: Notebook, dirty: Bool = true, synced: String? = nil) {
        guard let data = try? encoder.encode(nb) else { return }
        try? data.write(to: notebookURL(nb.id), options: protection)
        var e = index[nb.id] ?? NotebookEntry(id: nb.id, title: nb.title)
        describe(&e, nb)
        e.modified = max(nb.modified, dirty ? nowMS() : e.modified)
        e.dirty = dirty
        if let synced { e.synced = synced }
        if dirty { e.filesSynced = false }
        e.deleted = nil
        e.offloaded = false
        e.bytes = data.count + nb.assets.reduce(0) { $0 + fileSize(assetURL($1)) }
        index[nb.id] = e
        writeIndex()
    }

    private func describe(_ e: inout NotebookEntry, _ nb: Notebook) {
        e.title = nb.title
        e.folder = nb.folder
        e.sections = nb.layout.sections.count
        e.pages = nb.pages.count
        e.cover = nb.order.first
    }

    func update(_ id: String, _ change: (inout NotebookEntry) -> Void) {
        guard var e = index[id] else { return }
        change(&e)
        index[id] = e
        writeIndex()
    }

    func markSynced(_ id: String, digest: String) {
        update(id) {
            $0.dirty = false
            $0.synced = digest
        }
    }

    func opened(_ id: String) {
        update(id) { $0.lastOpened = nowMS() }
    }

    /// Delete here; keep a marker until the computer has heard about it.
    func delete(_ id: String) {
        try? FileManager.default.removeItem(at: notebookURL(id))
        var e = index[id] ?? NotebookEntry(id: id, title: "")
        e.deleted = nowMS()
        e.dirty = true
        index[id] = e
        writeIndex()
        removeUnusedFiles()
    }

    /// Forget a notebook entirely (after the computer confirmed a delete).
    func forget(_ id: String) {
        if let nb = load(id) { for p in nb.pages.keys { try? FileManager.default.removeItem(at: thumbURL(p)) } }
        try? FileManager.default.removeItem(at: notebookURL(id))
        index[id] = nil
        writeIndex()
        removeUnusedFiles()
    }

    // MARK: offloading

    /// Remove a notebook's ink and files from this iPad, keeping its outline
    /// (sections, page titles) and thumbnails. Only for notebooks the computer
    /// has (see NotebookEntry.canOffload).
    @discardableResult
    func offload(_ id: String) -> Bool {
        guard let e = index[id], let nb = load(id), e.canOffload(digest: digest(nb)) else { return false }
        var outline = nb
        for key in outline.pages.keys {
            outline.pages[key]?.strokes = []
            outline.pages[key]?.gone = []
        }
        guard let data = try? encoder.encode(outline) else { return false }
        try? data.write(to: notebookURL(id), options: protection)
        update(id) {
            $0.offloaded = true
            $0.bytes = data.count
        }
        removeUnusedFiles()
        return true
    }

    /// Replace an offloaded outline (or a newer version of it) from the computer.
    func saveOutline(_ nb: Notebook, synced: String) {
        var outline = nb
        for key in outline.pages.keys {
            outline.pages[key]?.strokes = []
            outline.pages[key]?.gone = []
        }
        guard let data = try? encoder.encode(outline) else { return }
        try? data.write(to: notebookURL(nb.id), options: protection)
        var e = index[nb.id] ?? NotebookEntry(id: nb.id, title: nb.title)
        describe(&e, nb)
        e.modified = nb.modified
        e.synced = synced
        e.dirty = false
        e.filesSynced = true
        e.offloaded = true
        e.deleted = nil
        e.bytes = data.count
        index[nb.id] = e
        writeIndex()
    }

    /// Files no notebook on this iPad still shows.
    private func removeUnusedFiles() {
        var used = Set<String>()
        for e in index.values where !e.offloaded && e.deleted == nil {
            if let nb = load(e.id) { used.formUnion(nb.assets) }
        }
        let dir = root.appendingPathComponent("assets")
        for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where !used.contains(name) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    /// Bytes OpenPad's notebooks and files take on this iPad.
    func bytesUsed() -> Int {
        ["notebooks", "assets", "thumbs"].reduce(0) { total, dir in
            let url = root.appendingPathComponent(dir)
            let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
            return total + names.reduce(0) { $0 + fileSize(url.appendingPathComponent($1)) }
        }
    }

    private func fileSize(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0
    }

    // MARK: folders

    /// Every folder: those notebooks are filed in, their parents, and empty ones made here.
    var folders: [String] {
        var all = Set(extraFolders)
        for e in index.values where e.deleted == nil && !e.folder.isEmpty {
            var parts = e.folder.split(separator: "/").map(String.init)
            while !parts.isEmpty {
                all.insert(parts.joined(separator: "/"))
                parts.removeLast()
            }
        }
        return all.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func addFolder(_ path: String) {
        guard !path.isEmpty, !extraFolders.contains(path) else { return }
        extraFolders.append(path)
        saveFolders()
    }

    func removeFolder(_ path: String) {
        extraFolders.removeAll { $0 == path || $0.hasPrefix(path + "/") }
        saveFolders()
    }

    private func saveFolders() {
        if let data = try? encoder.encode(extraFolders) {
            try? data.write(to: root.appendingPathComponent("folders.json"), options: protection)
        }
    }

    // MARK: thumbnails

    func thumbnail(_ pageID: String) -> UIImage? {
        UIImage(contentsOfFile: thumbURL(pageID).path)
    }

    private static func thumbKey(_ p: Page) -> String {
        "\(p.t).\(p.strokes.count).\(p.strokes.last?.id ?? "").\(p.gone.count)"
    }

    /// Redraw thumbnails of pages that changed (a few at a time).
    func refreshThumbnails(_ nb: Notebook, limit: Int = 60) {
        var made = 0
        for id in nb.order {
            guard made < limit, let page = nb.pages[id] else { continue }
            let key = Self.thumbKey(page)
            if thumbKeys[id] == key { continue }
            let image = PageRenderer.thumbnail(page, width: 240, store: self)
            if let jpeg = image.jpegData(compressionQuality: 0.7) {
                try? jpeg.write(to: thumbURL(id), options: protection)
                thumbKeys[id] = key
                made += 1
            }
        }
        if made > 0, let data = try? encoder.encode(thumbKeys) {
            try? data.write(to: root.appendingPathComponent("thumbs/index.json"), options: protection)
        }
    }

    // MARK: assets

    func hasAsset(_ sha: String) -> Bool { FileManager.default.fileExists(atPath: assetURL(sha).path) }

    func assetData(_ sha: String) -> Data? { try? Data(contentsOf: assetURL(sha)) }

    @discardableResult
    func putAsset(_ data: Data) -> String {
        let sha = sha256Hex(data)
        if !hasAsset(sha) { try? data.write(to: assetURL(sha), options: protection) }
        return sha
    }

    /// Store a downloaded file only if it matches its name.
    func putAsset(_ data: Data, expected sha: String) -> Bool {
        guard sha256Hex(data) == sha else { return false }
        if !hasAsset(sha) { try? data.write(to: assetURL(sha), options: protection) }
        return true
    }

    // MARK: the connected computer

    var link: SavedLink? {
        get {
            guard let data = try? Data(contentsOf: root.appendingPathComponent("link.json")) else { return nil }
            return try? decoder.decode(SavedLink.self, from: data)
        }
        set {
            let url = root.appendingPathComponent("link.json")
            if let newValue, let data = try? encoder.encode(newValue) {
                try? data.write(to: url, options: protection)
            } else {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}
