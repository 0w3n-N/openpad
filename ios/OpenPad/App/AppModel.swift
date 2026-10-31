import Foundation
import Observation
import OpenPadCore
import UIKit

/// Extra running time after the app goes to the background.
final class BackgroundTask: @unchecked Sendable {
    var id = UIBackgroundTaskIdentifier.invalid

    @MainActor
    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}

/// The drawing tools (web/editor.js's tools).
enum InkTool: String, CaseIterable {
    case pen, highlighter, eraser, lasso, shape
}

struct Peers: Equatable {
    var pads = 0
    var views = 0
    var guests = 0
}

/// The app's state: notebooks on this iPad (offloaded ones as outlines), the
/// connected computer, sync, search, and the live session that shows the open
/// notebook on the computer (the same protocol as web/app.js).
@MainActor
@Observable
final class AppModel {
    @ObservationIgnored let store = Store()
    @ObservationIgnored let text = TextIndex(root: Store.defaultRoot)
    var library: [NotebookEntry] = []
    var folders: [String] = []
    var link: ServerLink?
    var syncState: SyncState = .none
    var notebook: Notebook?  // the open notebook
    var pageID: String?
    var socketConnected = false
    var liveReady = false  // the open notebook is the one on the computer's screen
    var peers = Peers()
    var liveWindow = "idle"  // desktop annotation: idle, picking, live
    var liveFrame: UIImage?
    var notice: String?
    var downloading: Set<String> = []
    var bytesUsed = 0
    var cast: Bool = UserDefaults.standard.object(forKey: "cast") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(cast, forKey: "cast")
            liveReady = false
            castCurrent()
        }
    }
    var fingerDrawing: Bool = UserDefaults.standard.bool(forKey: "fingerDrawing") {
        didSet {
            UserDefaults.standard.set(fingerDrawing, forKey: "fingerDrawing")
            canvas?.applySettings()
        }
    }
    // The drawing tools, kept between launches (except the eraser and lasso).
    var tool: InkTool = InkTool(rawValue: UserDefaults.standard.string(forKey: "tool") ?? "") ?? .pen {
        didSet {
            UserDefaults.standard.set([.pen, .highlighter, .shape].contains(tool) ? tool.rawValue : previousTool.rawValue, forKey: "tool")
            canvas?.toolChanged()
        }
    }
    @ObservationIgnored var previousTool: InkTool = .pen
    var shape: Ink.Shape = Ink.Shape(rawValue: UserDefaults.standard.string(forKey: "shape") ?? "") ?? .line {
        didSet { UserDefaults.standard.set(shape.rawValue, forKey: "shape") }
    }
    var color: String = UserDefaults.standard.string(forKey: "color").flatMap { Ink.colors.contains($0) ? $0 : nil } ?? Ink.colors[0] {
        didSet { UserDefaults.standard.set(color, forKey: "color") }
    }
    var width: Double = UserDefaults.standard.object(forKey: "width").flatMap { $0 as? Double }.flatMap { Ink.widths.contains($0) ? $0 : nil } ?? 3.5 {
        didSet { UserDefaults.standard.set(width, forKey: "width") }
    }
    /// How much pressing harder thickens the line (0: an even line).
    var pressure: Double = UserDefaults.standard.object(forKey: "pressure") as? Double ?? 0.35 {
        didSet { UserDefaults.standard.set(pressure, forKey: "pressure") }
    }
    var canUndo = false
    var canRedo = false

    /// Sync by itself whenever the computer is reachable (otherwise: Sync buttons only).
    var autoSync: Bool = UserDefaults.standard.object(forKey: "autoSync") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoSync, forKey: "autoSync") }
    }
    /// Keep at most this much here (MB; 0: no limit). Beyond it, the least
    /// recently opened notebooks the computer has are offloaded.
    var storageLimitMB: Int = UserDefaults.standard.object(forKey: "storageLimitMB") as? Int ?? 5120 {
        didSet {
            UserDefaults.standard.set(storageLimitMB, forKey: "storageLimitMB")
            enforceStorageLimit()
        }
    }

    @ObservationIgnored weak var canvas: PageCanvasController?
    @ObservationIgnored private var live: LiveSession?
    @ObservationIgnored private(set) var sync: SyncEngine?
    @ObservationIgnored private var saveWork: DispatchWorkItem?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var noticeWork: DispatchWorkItem?

    init() {
        if let saved = store.link, let l = ServerLink(saved: saved) {
            link = l
        }
        #if DEBUG
        DemoLaunch.prepare(self)
        #endif
        refreshLibrary()
        startLink()
        enforceStorageLimit()
        #if DEBUG
        DemoLaunch.open(self)
        #endif
    }

    func say(_ text: String, seconds: Double = 3) {
        notice = text
        noticeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.notice = nil }
        noticeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    func refreshLibrary() {
        library = store.library
        folders = store.folders
        bytesUsed = store.bytesUsed()
    }

    // MARK: - the computer

    func setLink(_ l: ServerLink?) {
        live?.stop()
        live = nil
        sync = nil
        link = l
        store.link = l?.saved
        liveReady = false
        socketConnected = false
        startLink()
        if l != nil, notebook != nil { castCurrent() }
    }

    private func startLink() {
        timer?.invalidate()
        guard let link else {
            syncState = .none
            return
        }
        link.onBaseChange = { [weak self] l in
            Task { @MainActor in self?.store.link = l.saved }
        }
        let engine = SyncEngine(link: link, store: store)
        engine.onState = { [weak self] s in self?.syncState = s }
        engine.onChanged = { [weak self] id, nb in self?.notebookChanged(id, nb) }
        engine.onPassDone = { [weak self] in
            self?.enforceStorageLimit()
            self?.refreshLibrary()
        }
        engine.isBusy = { [weak self] in self?.canvas?.drawingActive ?? false }
        sync = engine
        let session = LiveSession { [weak self] in
            self?.link?.webSocketURL ?? URL(string: "ws://127.0.0.1:9/")!
        }
        session.onMessage = { [weak self] m in self?.handle(m) }
        session.onFrame = { [weak self] d in self?.frameArrived(d) }
        session.onStatus = { [weak self] ok in self?.socketStatus(ok) }
        live = session
        session.start()
        if autoSync { engine.run() }
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.autoSync else { return }
                self.sync?.run()
            }
        }
    }

    func syncNow() {
        sync?.run()
    }

    /// The app is going to the background: save, sync, and write readable PDFs.
    func backgrounded() {
        flushSave()
        guard let sync, autoSync else { return }
        let task = BackgroundTask()
        task.id = UIApplication.shared.beginBackgroundTask(withName: "sync") { task.end() }
        sync.run()
        Task {
            try? await sync.buildPDFs(force: true)
            task.end()
        }
    }

    private func notebookChanged(_ id: String, _ nb: Notebook?) {
        refreshLibrary()
        guard let nb else {
            text.remove(notebook: id)
            if notebook?.id == id {
                close(deleted: true)
                say("This notebook was deleted on another device.")
            }
            return
        }
        text.schedule(nb, store: store)
        guard let open = notebook, open.id == id else { return }
        notebook = merge(open, nb)
        if let pageID, notebook?.pages[pageID] == nil { self.pageID = notebook?.order.first }
        canvasReload()
    }

    private func socketStatus(_ ok: Bool) {
        socketConnected = ok
        liveReady = false
        if ok {
            if autoSync { sync?.run() }
            castCurrent()
        }
    }

    /// Put the open notebook on the computer's screen (after syncing it there),
    /// or, with "Show on the computer" off, make sure it isn't there: otherwise
    /// edits that sync in the background would still be shown to guests.
    func castCurrent() {
        guard socketConnected, let nb = notebook else { return }
        guard cast else {
            live?.send(["t": "hide", "id": nb.id])
            return
        }
        guard let sync else { return }
        Task {
            try? await sync.push(nb)
            guard notebook?.id == nb.id else { return }
            live?.send(["t": "open", "id": nb.id, "page": pageID ?? ""])
        }
    }

    private func send(_ obj: [String: Any]) {
        guard liveReady, cast else { return }
        live?.send(obj)
    }

    func sendCursor(_ p: CGPoint?) {
        guard liveReady, cast, let pageID else { return }
        if let p {
            live?.send(["t": "cursor", "page": pageID, "x": Double(p.x), "y": Double(p.y)])
        } else {
            live?.send(["t": "cursor", "hide": true])
        }
    }

    // MARK: - drawing tools

    func setTool(_ t: InkTool) {
        if t == .eraser, tool != .eraser { previousTool = tool }
        tool = t
    }

    /// The Pencil's double-tap (or squeeze), when set to switch to the eraser.
    func toggleEraser() {
        setTool(tool == .eraser ? previousTool : .eraser)
        say(tool == .eraser ? "Eraser" : tool == .highlighter ? "Highlighter" : tool == .shape ? "Shapes" : "Pen", seconds: 0.7)
    }

    /// The Pencil's double-tap, when set to switch to the previous tool.
    func switchToPreviousTool() {
        let p = previousTool
        previousTool = tool
        tool = p
    }

    /// A color from the toolbar: recolors a selection, and otherwise picks
    /// the pen back up if the eraser or lasso was in hand.
    func pickColor(_ c: String) {
        color = c
        if tool == .eraser || tool == .lasso {
            if let canvas, canvas.hasSelection { return canvas.recolorSelection(c) }
            setTool(.pen)
        }
    }

    // MARK: - strokes from this iPad

    /// A stroke has started: the computer shows it as it's written.
    func strokeStarted(page: String, stroke: Stroke) {
        send(["t": "begin", "page": page, "s": jsonObject(stroke)])
    }

    func strokePoints(id: String, points: [[Double]]) {
        send(["t": "pts", "id": id, "pts": points])
    }

    /// The stroke is done: keep it.
    func strokeFinished(page: String, stroke: Stroke) {
        guard var nb = notebook else { return }
        apply(.begin(page: page, stroke: stroke), to: &nb)
        notebook = nb
        saveSoon()
        send(["t": "end", "id": stroke.id])
        canvasReload()
    }

    /// A stroke that was started but isn't kept (cancelled, or replaced by a
    /// straight line).
    func strokeCancelled(page: String, id: String) {
        guard var nb = notebook else { return }
        apply(.remove(page: page, ids: [id]), to: &nb)
        notebook = nb
        saveSoon()
        send(["t": "remove", "page": page, "ids": [id]])
    }

    // MARK: - live session messages

    private func handle(_ m: [String: Any]) {
        guard let t = m["t"] as? String else { return }
        switch t {
        case "peers":
            readPeers(m)
        case "error":
            if let e = m["error"] as? String { say(e, seconds: 4) }
        case "live":
            liveMessage(m)
        case "sync-request":
            syncForComputer()
        case "state":
            readPeers(m)
            liveWindow = ((m["live"] as? [String: Any])?["state"] as? String) ?? "idle"
            guard let open = notebook, cast, let theirs = decodeJSON(Notebook.self, from: m["nb"]) else { return }
            guard theirs.id == open.id else {
                // Another device put something else on screen; don't fight it.
                liveReady = false
                return
            }
            liveReady = true
            let merged = merge(open, theirs)
            notebook = merged
            if let page = m["page"] as? String, page != pageID, merged.pages[page] != nil { show(page, tell: false) } else { canvasReload() }
            saveSoon()
            if digest(merged) != digest(theirs), let sync { Task { try? await sync.push(merged) } }
        case "merge":
            guard liveReady, let open = notebook, let part = m["nb"] as? [String: Any] else { return }
            notebook = mergePartial(open, part)
            if let pageID, notebook?.pages[pageID] == nil { show(notebook?.order.first) } else { canvasReload() }
            saveSoon()
        case "goto":
            guard liveReady, let page = m["page"] as? String, notebook?.pages[page] != nil else { return }
            show(page, tell: false)
        case "end":
            guard liveReady, let id = m["id"] as? String else { return }
            canvas?.remoteEnded(id)
            saveSoon()
        case "begin", "pts", "remove", "restore":
            guard liveReady, var nb = notebook, let op = liveOp(t, m) else { return }
            let page = apply(op, to: &nb)
            notebook = nb
            switch op {
            case let .begin(_, stroke) where page == pageID:
                canvas?.remoteBegan(stroke.id)
            case let .points(id, _) where page == pageID:
                canvas?.remoteMoved(id)
            case .remove, .restore:
                if page == pageID { canvasReload() }
                saveSoon()
            default:
                break
            }
        default:
            break
        }
    }

    /// The Sync button on the computer: sync everything now and report back.
    private func syncForComputer() {
        guard let sync else { return }
        flushSave()
        say("Syncing with \(link?.displayName ?? "the computer")…", seconds: 30)
        Task {
            do {
                let n = try await sync.syncAll()
                live?.send(["t": "sync-done", "ok": true, "notebooks": n])
                say("Synced \(n) notebook\(n == 1 ? "" : "s")")
            } catch {
                live?.send(["t": "sync-done", "ok": false, "notebooks": 0, "error": error.localizedDescription])
                say("Sync failed: \(error.localizedDescription)", seconds: 5)
            }
            refreshLibrary()
        }
    }

    private func liveOp(_ t: String, _ m: [String: Any]) -> LiveOp? {
        switch t {
        case "begin":
            guard let page = m["page"] as? String, let s = decodeJSON(Stroke.self, from: m["s"]) else { return nil }
            return .begin(page: page, stroke: s)
        case "pts":
            guard let id = m["id"] as? String, let pts = m["pts"] as? [[Double]] else { return nil }
            return .points(stroke: id, pts: pts)
        case "remove":
            guard let page = m["page"] as? String, let ids = m["ids"] as? [String] else { return nil }
            return .remove(page: page, ids: ids)
        case "restore":
            guard let page = m["page"] as? String, let s = decodeJSON([Stroke].self, from: m["strokes"]) else { return nil }
            return .restore(page: page, strokes: s)
        default:
            return nil
        }
    }

    private func readPeers(_ m: [String: Any]) {
        peers = Peers(pads: m["pads"] as? Int ?? 0, views: m["views"] as? Int ?? 0, guests: m["guests"] as? Int ?? 0)
    }

    private func liveMessage(_ m: [String: Any]) {
        let state = m["state"] as? String ?? ""
        switch state {
        case "needs-desktop":
            say(peers.views > 0 ? "On your computer, click “Choose a window” in the OpenPad window."
                                : "Open the OpenPad window on your computer first, then try again.", seconds: 5)
        case "source-stop":
            break
        case "picking":
            liveWindow = "picking"
            say("Choose the window in the picker on your computer…", seconds: 5)
        case "live":
            liveWindow = "live"
            say("The window is live. Draw on it.")
        case "error":
            liveWindow = "idle"
            say(m["error"] as? String ?? "Window capture failed", seconds: 5)
        default:
            liveWindow = "idle"
            switch m["reason"] as? String {
            case "cancelled": say("Window sharing cancelled")
            case "closed": say("The window closed. Its last frame stays on the page.")
            case "stopped": say("Stopped. The last frame stays on the page.")
            default: if let e = m["error"] as? String { say(e) }
            }
        }
    }

    private func frameArrived(_ data: Data) {
        guard let image = UIImage(data: data) else { return }
        liveFrame = image
        canvas?.liveFrameChanged(image)
    }

    func toggleWindowAnnotation() {
        guard liveReady else {
            say("Connect to your computer and open a notebook first.")
            return
        }
        live?.send(["t": "live", "action": liveWindow == "idle" ? "start" : "stop"])
    }

    func clearGuestInk() {
        guard let pageID else { return }
        send(["t": "clearguests", "page": pageID])
    }

    // MARK: - library

    @discardableResult
    func createNotebook(title: String, size: PageSize, folder: String = "") -> String {
        var nb = newNotebook(title: title.isEmpty ? "Notes" : String(title.prefix(120)), size: size,
                             section: "Notes", paper: size == .wide ? "grid" : "lines")
        nb.folder = folder
        store.save(nb)
        refreshLibrary()
        if autoSync { sync?.run() }
        return nb.id
    }

    func open(_ id: String, page: String? = nil) {
        guard let entry = store.index[id] else { return }
        if entry.offloaded {
            guard let sync, socketConnected || syncState == .ok else {
                say("“\(entry.title)” is stored on \(link?.displayName ?? "your computer"). Connect to the same Wi-Fi to open it.", seconds: 5)
                return
            }
            downloading.insert(id)
            Task {
                defer { downloading.remove(id) }
                do {
                    let nb = try await sync.download(id)
                    refreshLibrary()
                    text.schedule(nb, store: store)
                    open(id, page: page)
                } catch {
                    say("Couldn’t download “\(entry.title)”: \(error.localizedDescription)", seconds: 5)
                }
            }
            return
        }
        guard let nb = store.load(id) else {
            refreshLibrary()
            return
        }
        notebook = nb
        liveReady = false
        store.opened(id)
        let last = page ?? UserDefaults.standard.string(forKey: "last.\(id)")
        pageID = last.flatMap { nb.pages[$0] != nil ? $0 : nil } ?? nb.order.first
        castCurrent()
        text.schedule(nb, store: store)
    }

    func close(deleted: Bool = false) {
        if !deleted { flushSave() }
        let id = notebook?.id
        notebook = nil
        pageID = nil
        liveReady = false
        refreshLibrary()
        if let id, let sync, !deleted, autoSync {
            sync.run()
            sync.queuePDF(id, after: 1)
        }
        enforceStorageLimit()
    }

    /// Change a closed notebook's title or folder.
    private func editMeta(_ id: String, _ change: (inout Notebook) -> Void) {
        if var nb = notebook, nb.id == id {
            change(&nb)
            nb.metaT = nowMS()
            notebook = nb
            send(["t": "merge", "nb": partial(nb, meta: true)])
            flushSave()
        } else if store.index[id]?.offloaded == true {
            say("Open it first (it’s offloaded to the computer).")
            return
        } else if var nb = store.load(id) {
            change(&nb)
            nb.metaT = nowMS()
            store.save(nb)
        }
        refreshLibrary()
        if autoSync { sync?.run() }
    }

    func rename(_ id: String, to title: String) {
        let clean = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        guard !clean.isEmpty else { return }
        editMeta(id) { $0.title = clean }
    }

    func move(_ id: String, toFolder folder: String) {
        editMeta(id) { $0.folder = folder }
    }

    func delete(_ id: String) {
        if notebook?.id == id { close(deleted: true) }
        store.delete(id)
        text.remove(notebook: id)
        refreshLibrary()
        if autoSync { sync?.run() }
    }

    // MARK: - folders

    /// Folder names as typed: up to four levels, separated by "/".
    static func cleanFolder(_ s: String) -> String {
        s.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
            .filter { !$0.isEmpty }.prefix(4).map { String($0.prefix(60)) }.joined(separator: "/")
    }

    func createFolder(_ name: String, in parent: String) {
        let path = Self.cleanFolder(parent.isEmpty ? name : "\(parent)/\(name)")
        guard !path.isEmpty else { return }
        store.addFolder(path)
        refreshLibrary()
    }

    func renameFolder(_ path: String, to name: String) {
        let parent = path.split(separator: "/").dropLast().joined(separator: "/")
        let new = Self.cleanFolder(parent.isEmpty ? name : "\(parent)/\(name)")
        guard !new.isEmpty, new != path else { return }
        let moved = library.filter { $0.folder == path || $0.folder.hasPrefix(path + "/") }
        if moved.contains(where: \.offloaded) {
            say("Some notebooks in it are offloaded. Connect to your computer first.")
            return
        }
        for e in moved { move(e.id, toFolder: new + e.folder.dropFirst(path.count)) }
        store.removeFolder(path)
        store.addFolder(new)
        refreshLibrary()
    }

    func deleteFolder(_ path: String) -> Bool {
        guard !library.contains(where: { $0.folder == path || $0.folder.hasPrefix(path + "/") }) else { return false }
        store.removeFolder(path)
        refreshLibrary()
        return true
    }

    // MARK: - storage

    /// Offload the least recently opened notebooks (that the computer has) until
    /// OpenPad is under its storage limit, or there's room on the iPad again.
    func enforceStorageLimit(force: Bool = false) {
        var used = store.bytesUsed()
        let limit = storageLimitMB > 0 ? storageLimitMB * 1_048_576 : Int.max
        let lowDisk = (freeDiskBytes() ?? Int.max) < 1_073_741_824
        guard force || used > limit || lowDisk else {
            bytesUsed = used
            return
        }
        let target = force ? 0 : (lowDisk ? used / 2 : Int(Double(limit) * 0.9))
        let day: Int64 = 24 * 3600 * 1000
        let candidates = store.library
            .filter { !$0.offloaded && !$0.keep && $0.id != notebook?.id && (force || nowMS() - max($0.lastOpened, $0.modified) > day) }
            .sorted { max($0.lastOpened, $0.modified) < max($1.lastOpened, $1.modified) }
        var offloaded = 0
        for e in candidates where used > target {
            if store.offload(e.id) {
                offloaded += 1
                used = store.bytesUsed()
            }
        }
        if offloaded > 0 { say("Offloaded \(offloaded) notebook\(offloaded == 1 ? "" : "s") to \(link?.displayName ?? "your computer") to save space.") }
        refreshLibrary()
    }

    private func freeDiskBytes() -> Int? {
        let values = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage.map { Int($0) }
    }

    func removeDownload(_ id: String) {
        guard let e = store.index[id] else { return }
        if store.offload(id) {
            refreshLibrary()
            say("“\(e.title)” is now only on \(link?.displayName ?? "your computer"). It downloads again when you open it.")
        } else {
            say(link == nil ? "Connect to your computer first: notebooks are only offloaded once it has them."
                            : "Sync “\(e.title)” first: the computer doesn’t have its latest changes yet.", seconds: 4)
            if autoSync { sync?.run() }
        }
    }

    func setKeep(_ id: String, _ keep: Bool) {
        store.update(id) { $0.keep = keep }
        refreshLibrary()
    }

    // MARK: - editing

    private func saveSoon() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flushSave() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func flushSave() {
        saveWork?.cancel()
        saveWork = nil
        guard let nb = notebook else { return }
        store.save(nb)
        store.refreshThumbnails(nb, limit: 4)
        text.schedule(nb, store: store)
    }

    private func canvasReload() { canvas?.reloadFromModel() }

    /// Show a page here (and, unless it came from there, on the computer).
    func show(_ id: String?, tell: Bool = true) {
        guard let id, notebook?.pages[id] != nil else { return }
        pageID = id
        if let nbID = notebook?.id { UserDefaults.standard.set(id, forKey: "last.\(nbID)") }
        if let model = canvas?.model { canvas?.show(pageID: id, refit: true, from: model) }
        if tell { send(["t": "goto", "page": id]) }
    }

    func go(_ delta: Int) {
        guard let nb = notebook, let pageID, let i = nb.order.firstIndex(of: pageID) else { return }
        let j = i + delta
        guard nb.order.indices.contains(j) else { return }
        show(nb.order[j])
    }

    /// Strokes drawn or erased on this iPad.
    func localStrokes(page: String, added: [Stroke], removed: [String]) {
        guard var nb = notebook else { return }
        if !removed.isEmpty { apply(.remove(page: page, ids: removed), to: &nb) }
        for s in added { apply(.begin(page: page, stroke: s), to: &nb) }
        notebook = nb
        saveSoon()
        if !removed.isEmpty { send(["t": "remove", "page": page, "ids": removed]) }
        for s in added {
            send(["t": "begin", "page": page, "s": jsonObject(s)])
            send(["t": "end", "id": s.id])
        }
        if page == pageID { canvasReload() }
    }

    /// A structural edit: new layout (and pages), sent as a partial notebook.
    private func changeLayout(_ mutate: (inout [Section]) -> Void, pages: [Page] = [], gone: [String] = []) {
        guard var nb = notebook else { return }
        var sections = nb.layout.sections
        mutate(&sections)
        nb.layout = Layout(t: nowMS(), sections: sections)
        for p in pages { nb.pages[p.id] = p }
        for id in gone {
            nb.pages[id] = nil
            if !nb.goneP.contains(id) { nb.goneP.append(id) }
        }
        nb.goneP.sort { $0.unicodeScalars.lexicographicallyPrecedes($1.unicodeScalars) }
        nb = finish(nb)
        notebook = nb
        send(["t": "merge", "nb": partial(nb, layout: true, pages: pages.map(\.id), goneP: gone)])
        saveSoon()
    }

    /// Insert pages after `after` (default: the current page), in its section.
    private func insert(_ pages: [Page], after: String? = nil) {
        guard let nb = notebook, !pages.isEmpty else { return }
        let afterID = after ?? pageID
        guard let sec = afterID.flatMap({ nb.section(of: $0) }) ?? nb.layout.sections.last else { return }
        var placed = pages
        for i in placed.indices { placed[i].sec = sec.id }
        changeLayout({ secs in
            guard let i = secs.firstIndex(where: { $0.id == sec.id }) else { return }
            let at = afterID.flatMap { secs[i].pages.firstIndex(of: $0) }.map { $0 + 1 } ?? secs[i].pages.count
            secs[i].pages.insert(contentsOf: placed.map(\.id), at: at)
        }, pages: placed)
        show(placed[0].id)
    }

    func addPage(after: String? = nil) {
        guard let nb = notebook else { return }
        let cur = (after ?? pageID).flatMap { nb.pages[$0] }
        var page = blankPage(section: "", size: nb.pageSize, paper: cur.map { $0.bg == nil ? $0.paper : "lines" } ?? "lines")
        if let cur, cur.bg == nil {
            page.h = cur.h
            page.pt = cur.pt
        }
        insert([page], after: after)
    }

    func deletePage(_ id: String? = nil) {
        guard let nb = notebook, let id = id ?? pageID, nb.order.count > 1, let i = nb.order.firstIndex(of: id) else { return }
        let next = i + 1 < nb.order.count ? nb.order[i + 1] : nb.order[i - 1]
        changeLayout({ secs in for k in secs.indices { secs[k].pages.removeAll { $0 == id } } }, gone: [id])
        if id == pageID { show(next) } else { canvasReload() }
    }

    func movePage(_ id: String, toSection sec: String) {
        guard var page = notebook?.pages[id] else { return }
        page.sec = sec
        page.t = nowMS()
        changeLayout({ secs in
            for k in secs.indices { secs[k].pages.removeAll { $0 == id } }
            if let i = secs.firstIndex(where: { $0.id == sec }) { secs[i].pages.append(id) }
        }, pages: [page])
    }

    func movePage(_ id: String, by delta: Int) {
        changeLayout { secs in
            guard let s = secs.firstIndex(where: { $0.pages.contains(id) }), let i = secs[s].pages.firstIndex(of: id),
                  secs[s].pages.indices.contains(i + delta) else { return }
            secs[s].pages.swapAt(i, i + delta)
        }
    }

    func setPageTitle(_ id: String, _ title: String) {
        guard var nb = notebook, var page = nb.pages[id] else { return }
        page.title = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        page.t = nowMS()
        nb.pages[id] = page
        notebook = nb
        send(["t": "merge", "nb": partial(nb, pages: [id])])
        saveSoon()
    }

    func addSection(_ title: String) {
        guard let nb = notebook else { return }
        let id = newID()
        let paper = pageID.flatMap { nb.pages[$0] }.map { $0.bg == nil ? $0.paper : "lines" } ?? "lines"
        let page = blankPage(section: id, size: nb.pageSize, paper: paper)
        let cur = pageID.flatMap { nb.section(of: $0) }?.id
        changeLayout({ secs in
            let at = cur.flatMap { c in secs.firstIndex { $0.id == c } }.map { $0 + 1 } ?? secs.count
            secs.insert(Section(id: id, title: String(title.prefix(80)), pages: [page.id]), at: at)
        }, pages: [page])
        show(page.id)
    }

    func renameSection(_ id: String, to title: String) {
        let clean = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        guard !clean.isEmpty else { return }
        changeLayout { secs in
            if let i = secs.firstIndex(where: { $0.id == id }) { secs[i].title = clean }
        }
    }

    func setSectionColor(_ id: String, _ color: String?) {
        changeLayout { secs in
            if let i = secs.firstIndex(where: { $0.id == id }) { secs[i].color = color }
        }
    }

    func moveSection(_ id: String, by delta: Int) {
        changeLayout { secs in
            guard let i = secs.firstIndex(where: { $0.id == id }), secs.indices.contains(i + delta) else { return }
            secs.swapAt(i, i + delta)
        }
    }

    func deleteSection(_ id: String) {
        guard let nb = notebook, nb.layout.sections.count > 1, let sec = nb.layout.sections.first(where: { $0.id == id }) else { return }
        let wasHere = pageID.map { sec.pages.contains($0) } ?? false
        changeLayout({ secs in secs.removeAll { $0.id == id } }, gone: sec.pages)
        if wasHere { show(notebook?.order.first) }
    }

    func setPaper(_ paper: String) {
        guard var nb = notebook, let pageID, var page = nb.pages[pageID] else { return }
        page.paper = paper
        page.t = nowMS()
        nb.pages[pageID] = page
        notebook = nb
        send(["t": "merge", "nb": partial(nb, pages: [pageID])])
        saveSoon()
        canvasReload()
    }

    // MARK: - PDFs, scans, photos

    private func readPDF(_ url: URL) -> (sha: String, sizes: [[Double]], name: String)? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url), data.count <= 200 * 1024 * 1024 else {
            say("Couldn't read \(url.lastPathComponent) (PDFs up to 200 MB).")
            return nil
        }
        guard data.starts(with: Array("%PDF-".utf8)), let sizes = PDFAssets.pageSizes(data) else {
            say("\(url.lastPathComponent) is not a PDF.")
            return nil
        }
        return (store.putAsset(data), sizes, String(url.deletingPathExtension().lastPathComponent.prefix(80)))
    }

    private func pdfPages(_ pdf: (sha: String, sizes: [[Double]], name: String), section: String) -> [Page] {
        let t = nowMS()
        return pdf.sizes.enumerated().map { i, wh in
            var p = blankPage(section: section, size: .letter, paper: "blank", t: t)
            p.h = (1000 * wh[1] / max(1, wh[0]) * 100).rounded() / 100
            p.pt = wh
            p.bg = Background(pdf: pdf.sha, n: i + 1)
            return p
        }
    }

    /// PDFs into the library: one notebook, with a section per PDF (a OneNote
    /// export, a semester of slides...).
    func importPDFs(_ urls: [URL], folder: String = "") {
        let pdfs = urls.compactMap(readPDF)
        guard let first = pdfs.first else { return }
        let t = nowMS()
        var sections: [Section] = []
        var pages: [String: Page] = [:]
        for pdf in pdfs {
            let secID = newID()
            let ps = pdfPages(pdf, section: secID)
            sections.append(Section(id: secID, title: pdf.name, pages: ps.map(\.id)))
            for p in ps { pages[p.id] = p }
        }
        let nb = finish(Notebook(id: newID(), title: pdfs.count == 1 ? first.name : "Imported PDFs", size: PageSize.letter.rawValue,
                                 folder: folder, metaT: t, created: t, layout: Layout(t: t, sections: sections), pages: pages))
        store.save(nb)
        refreshLibrary()
        if autoSync { sync?.run() }
        open(nb.id)
        say("Imported \(pdfs.count == 1 ? first.name : "\(pdfs.count) PDFs") (\(pages.count) pages)")
    }

    /// A PDF as a new section of the open notebook, after the current one.
    func importPDFAsSection(_ url: URL) {
        guard notebook != nil, let pdf = readPDF(url) else { return }
        let secID = newID()
        let ps = pdfPages(pdf, section: secID)
        let cur = pageID.flatMap { notebook?.section(of: $0) }?.id
        changeLayout({ secs in
            let at = cur.flatMap { c in secs.firstIndex { $0.id == c } }.map { $0 + 1 } ?? secs.count
            secs.insert(Section(id: secID, title: pdf.name, pages: ps.map(\.id)), at: at)
        }, pages: ps)
        afterFilesAdded()
        if let firstPage = ps.first { show(firstPage.id) }
        say("Added \(pdf.name) (\(ps.count) pages)")
    }

    /// A PDF's pages inserted after the current page.
    func insertPDFPages(_ url: URL) {
        guard notebook != nil, let pdf = readPDF(url) else { return }
        insert(pdfPages(pdf, section: ""))
        afterFilesAdded()
        say("Inserted \(pdf.sizes.count) page\(pdf.sizes.count == 1 ? "" : "s") from \(pdf.name)")
    }

    /// Scanned documents or photos, one page each, after the current page.
    func insertImages(_ images: [UIImage]) {
        guard notebook != nil else { return }
        let t = nowMS()
        let pages: [Page] = images.compactMap { image in
            let maxSide: CGFloat = 2400
            let k = min(1, maxSide / max(image.size.width, image.size.height))
            let size = CGSize(width: image.size.width * k, height: image.size.height * k)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let flat = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
            guard let jpeg = flat.jpegData(compressionQuality: 0.82) else { return nil }
            var p = blankPage(section: "", size: .letter, paper: "blank", t: t)
            p.h = (1000 * size.height / max(1, size.width) * 100).rounded() / 100
            let w = 612.0
            p.pt = [w, (w * Double(size.height / max(1, size.width)) * 100).rounded() / 100]
            p.bg = Background(img: store.putAsset(jpeg))
            return p
        }
        insert(pages)
        afterFilesAdded()
        say("Added \(pages.count) page\(pages.count == 1 ? "" : "s")")
    }

    /// New files must reach the computer before it can show the pages.
    private func afterFilesAdded() {
        flushSave()
        castCurrent()
    }

    /// A PDF of some pages, written to a temporary file for saving or sharing.
    func exportPDF(pageIDs: [String], title: String) -> URL? {
        guard let nb = notebook else { return nil }
        let pages = pageIDs.compactMap { nb.pages[$0] }
        var outline: [(String, Int)] = []
        if pages.count > 1 {
            for s in nb.layout.sections {
                if let first = s.pages.first, let i = pageIDs.firstIndex(of: first) { outline.append((s.title, i)) }
            }
        }
        let data = PDFExporter.render(pages: pages, title: title, store: store, liveFrame: liveFrame, outline: outline)
        return writeTemp(data, title)
    }

    func exportNotebookPDF(_ id: String) -> URL? {
        guard store.index[id]?.offloaded != true, let nb = store.load(id) else {
            say("Open it first (it’s offloaded to the computer).")
            return nil
        }
        let data = PDFExporter.render(pages: nb.order.compactMap { nb.pages[$0] }, title: nb.title, store: store, liveFrame: nil, outline: [])
        return writeTemp(data, nb.title)
    }

    private func writeTemp(_ data: Data, _ title: String) -> URL? {
        let safe = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(safe.prefix(80)).pdf")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            say("Couldn't create the PDF.")
            return nil
        }
    }
}
