import Foundation
import OpenPadCore

/// What the library shows about a notebook without loading its ink.
struct NotebookEntry: Codable, Identifiable, Equatable {
    var id: String
    var title: String
    var sections: Int = 1
    var pages: Int = 1
    var modified: Int64 = 0
    var dirty = true  // changed since the last sync
    var synced: String?  // digest the computer last confirmed
    var deleted: Int64?  // deleted here; the computer still has to hear about it
    var pdfDone: [String: String] = [:]  // section id -> digest of its last readable PDF
}

/// The computer this iPad is connected to.
struct SavedLink: Codable, Equatable {
    var base: String
    var key: String
    var name: String
    var alts: [String]
}

/// Notebooks on this iPad, in Application Support/OpenPad:
///   notebooks/<id>.json   one notebook (layout, pages, ink)
///   assets/<sha256>       PDFs and images pages show
///   index.json            library entries and sync bookkeeping
///   link.json             the connected computer
@MainActor
final class Store {
    let root: URL
    private(set) var index: [String: NotebookEntry] = [:]
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(root: URL? = nil) {
        let base = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenPad", isDirectory: true)
        self.root = base
        for dir in ["notebooks", "assets"] {
            try? FileManager.default.createDirectory(at: base.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        if let data = try? Data(contentsOf: base.appendingPathComponent("index.json")),
           let list = try? decoder.decode([NotebookEntry].self, from: data) {
            index = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
        }
    }

    private func notebookURL(_ id: String) -> URL { root.appendingPathComponent("notebooks/\(id).json") }
    func assetURL(_ sha: String) -> URL { root.appendingPathComponent("assets/\(sha)") }

    private func writeIndex() {
        let list = index.values.sorted { $0.id < $1.id }
        if let data = try? encoder.encode(list) {
            try? data.write(to: root.appendingPathComponent("index.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    // MARK: notebooks

    var library: [NotebookEntry] {
        index.values.filter { $0.deleted == nil }.sorted { $0.modified > $1.modified }
    }

    func load(_ id: String) -> Notebook? {
        guard index[id]?.deleted == nil, let data = try? Data(contentsOf: notebookURL(id)) else { return nil }
        return try? decoder.decode(Notebook.self, from: data)
    }

    /// Save a notebook. `dirty` marks it for the next sync.
    func save(_ nb: Notebook, dirty: Bool = true, synced: String? = nil) {
        guard let data = try? encoder.encode(nb) else { return }
        try? data.write(to: notebookURL(nb.id), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var e = index[nb.id] ?? NotebookEntry(id: nb.id, title: nb.title)
        e.title = nb.title
        e.sections = nb.layout.sections.count
        e.pages = nb.pages.count
        e.modified = max(nb.modified, dirty ? nowMS() : e.modified)
        e.dirty = dirty
        if let synced { e.synced = synced }
        e.deleted = nil
        index[nb.id] = e
        writeIndex()
    }

    func markSynced(_ id: String, digest: String) {
        guard var e = index[id] else { return }
        e.dirty = false
        e.synced = digest
        index[id] = e
        writeIndex()
    }

    /// Delete here; keep a marker until the computer has heard about it.
    func delete(_ id: String) {
        try? FileManager.default.removeItem(at: notebookURL(id))
        var e = index[id] ?? NotebookEntry(id: id, title: "")
        e.deleted = nowMS()
        e.dirty = true
        index[id] = e
        writeIndex()
    }

    /// Forget a notebook entirely (after the computer confirmed a delete).
    func forget(_ id: String) {
        try? FileManager.default.removeItem(at: notebookURL(id))
        index[id] = nil
        writeIndex()
    }

    func setPDFDone(_ id: String, section: String, digest: String) {
        guard var e = index[id] else { return }
        e.pdfDone[section] = digest
        index[id] = e
        writeIndex()
    }

    // MARK: assets

    func hasAsset(_ sha: String) -> Bool { FileManager.default.fileExists(atPath: assetURL(sha).path) }

    func assetData(_ sha: String) -> Data? { try? Data(contentsOf: assetURL(sha)) }

    @discardableResult
    func putAsset(_ data: Data) -> String {
        let sha = sha256Hex(data)
        if !hasAsset(sha) { try? data.write(to: assetURL(sha), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) }
        return sha
    }

    /// Store a downloaded file only if it matches its name.
    func putAsset(_ data: Data, expected sha: String) -> Bool {
        guard sha256Hex(data) == sha else { return false }
        if !hasAsset(sha) { try? data.write(to: assetURL(sha), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) }
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
                try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            } else {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}
