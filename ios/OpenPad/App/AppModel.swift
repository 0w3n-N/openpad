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

struct Peers: Equatable {
    var pads = 0
    var views = 0
    var guests = 0
}

/// The app's state: notebooks on this iPad, the connected computer, sync,
/// and the live session that shows the open notebook on the computer (the
/// same protocol as web/app.js).
@MainActor
@Observable
final class AppModel {
    @ObservationIgnored let store = Store()
    var library: [NotebookEntry] = []
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
    var cast: Bool = UserDefaults.standard.object(forKey: "cast") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(cast, forKey: "cast")
            liveReady = false
            if cast { castCurrent() }
        }
    }
    var fingerDrawing: Bool = UserDefaults.standard.bool(forKey: "fingerDrawing") {
        didSet {
            UserDefaults.standard.set(fingerDrawing, forKey: "fingerDrawing")
            canvas?.applySettings()
        }
    }

    @ObservationIgnored weak var canvas: PageCanvasController?
    @ObservationIgnored private var live: LiveSession?
    @ObservationIgnored private(set) var sync: SyncEngine?
    @ObservationIgnored private var saveWork: DispatchWorkItem?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var noticeWork: DispatchWorkItem?

    init() {
        library = store.library
        if let saved = store.link, let l = ServerLink(saved: saved) {
            link = l
        }
        #if DEBUG
        DemoLaunch.prepare(self)
        #endif
        startLink()
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

    func refreshLibrary() { library = store.library }

    // MARK: - the computer

    func setLink(_ l: ServerLink?) {
        live?.stop()
        live = nil
        sync = nil
        link = l
        store.link = l?.saved
        liveReady = false
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
        engine.onState = { [weak self] s in
            self?.syncState = s
            if s == .ok { self?.refreshLibrary() }  // sync dots on the cards
        }
        engine.onChanged = { [weak self] id, nb in self?.notebookChanged(id, nb) }
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
        engine.run()
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        guard let sync else { return }
        sync.run()
    }

    func syncNow() {
        sync?.run()
    }

    /// The app is going to the background: save, sync, and write readable PDFs.
    func backgrounded() {
        flushSave()
        guard let sync else { return }
        // Ask iPadOS for a little time to finish syncing.
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
        guard let open = notebook, open.id == id else { return }
        guard let nb else {
            close(deleted: true)
            say("This notebook was deleted on another device.")
            return
        }
        notebook = merge(open, nb)
        if let pageID, notebook?.pages[pageID] == nil { self.pageID = notebook?.order.first }
        canvasReload()
    }

    private func socketStatus(_ ok: Bool) {
        socketConnected = ok
        liveReady = false
        if ok {
            sync?.run()
            castCurrent()
        }
    }

    /// Put the open notebook on the computer's screen (after syncing it there).
    func castCurrent() {
        guard cast, socketConnected, let nb = notebook, let sync else { return }
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
            if let page = m["page"] as? String, page != pageID, merged.pages[page] != nil { show(page) } else { canvasReload() }
            saveSoon()
            if digest(merged) != digest(theirs), let sync { Task { try? await sync.push(merged) } }
        case "merge":
            guard liveReady, let open = notebook, let part = m["nb"] as? [String: Any] else { return }
            notebook = mergePartial(open, part)
            if let pageID, notebook?.pages[pageID] == nil { show(notebook?.order.first) } else { canvasReload() }
            saveSoon()
        case "goto":
            guard liveReady, let page = m["page"] as? String, notebook?.pages[page] != nil else { return }
            show(page)
        case "end":
            // PencilKit can't show half a stroke, so strokes appear when they end.
            guard liveReady, let id = m["id"] as? String, let pageID else { return }
            if notebook?.pages[pageID]?.strokes.contains(where: { $0.id == id }) == true { canvasReload() }
            saveSoon()
        case "begin", "pts", "remove", "restore":
            guard liveReady, var nb = notebook, let op = liveOp(t, m) else { return }
            let page = apply(op, to: &nb)
            notebook = nb
            if t == "remove" || t == "restore" {
                if page == pageID { canvasReload() }
                saveSoon()
            }
        default:
            break
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
    func createNotebook(title: String, size: PageSize) -> String {
        let nb = newNotebook(title: title.isEmpty ? "Notes" : String(title.prefix(120)), size: size,
                             section: "Notes", paper: size == .wide ? "grid" : "lines")
        store.save(nb)
        refreshLibrary()
        sync?.run()
        return nb.id
    }

    func open(_ id: String) {
        guard let nb = store.load(id) else {
            refreshLibrary()
            return
        }
        notebook = nb
        liveReady = false
        let last = UserDefaults.standard.string(forKey: "last.\(id)")
        pageID = last.flatMap { nb.pages[$0] != nil ? $0 : nil } ?? nb.order.first
        castCurrent()
    }

    func close(deleted: Bool = false) {
        if !deleted { flushSave() }
        let id = notebook?.id
        notebook = nil
        pageID = nil
        liveReady = false
        refreshLibrary()
        if let id, let sync, !deleted {
            sync.run()
            sync.queuePDF(id, after: 1)
        }
    }

    func rename(_ id: String, to title: String) {
        let clean = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        guard !clean.isEmpty else { return }
        if var nb = notebook, nb.id == id {
            nb.title = clean
            nb.metaT = nowMS()
            notebook = nb
            send(["t": "merge", "nb": partial(nb, meta: true)])
            saveSoon()
            flushSave()
        } else if var nb = store.load(id) {
            nb.title = clean
            nb.metaT = nowMS()
            store.save(nb)
        }
        refreshLibrary()
        sync?.run()
    }

    func delete(_ id: String) {
        if notebook?.id == id { close(deleted: true) }
        store.delete(id)
        refreshLibrary()
        sync?.run()
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
    }

    private func canvasReload() { canvas?.reloadFromModel() }

    /// Show a page here (and on the computer).
    func show(_ id: String?) {
        guard let id, notebook?.pages[id] != nil else { return }
        pageID = id
        if let nbID = notebook?.id { UserDefaults.standard.set(id, forKey: "last.\(nbID)") }
        if let model = canvas?.model { canvas?.show(pageID: id, refit: true, from: model) }
        send(["t": "goto", "page": id])
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

    func addPage(after: String? = nil) {
        guard let nb = notebook else { return }
        let afterID = after ?? pageID
        let cur = afterID.flatMap { nb.pages[$0] }
        guard let sec = afterID.flatMap({ nb.section(of: $0) }) ?? nb.layout.sections.last else { return }
        var page = blankPage(section: sec.id, size: nb.pageSize, paper: cur.map { $0.bg == nil ? $0.paper : "lines" } ?? "lines")
        if let cur, cur.bg == nil {
            page.h = cur.h
            page.pt = cur.pt
        }
        changeLayout({ secs in
            guard let i = secs.firstIndex(where: { $0.id == sec.id }) else { return }
            let at = afterID.flatMap { secs[i].pages.firstIndex(of: $0) }.map { $0 + 1 } ?? secs[i].pages.count
            secs[i].pages.insert(page.id, at: at)
        }, pages: [page])
        show(page.id)
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

    // MARK: - PDFs

    /// Import a PDF as a new notebook, or as a new section of the open one.
    func importPDF(_ url: URL, asSection: Bool) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url), data.count <= 200 * 1024 * 1024 else {
            say("Couldn't read that file (PDFs up to 200 MB).")
            return
        }
        guard data.starts(with: Array("%PDF-".utf8)), let sizes = PDFAssets.pageSizes(data) else {
            say("That file is not a PDF.")
            return
        }
        let sha = store.putAsset(data)
        let name = String(url.deletingPathExtension().lastPathComponent.prefix(80))
        let t = nowMS()
        func pages(_ sec: String) -> [Page] {
            sizes.enumerated().map { i, wh in
                var p = blankPage(section: sec, size: .letter, paper: "blank", t: t)
                p.h = (1000 * wh[1] / max(1, wh[0]) * 100).rounded() / 100
                p.pt = wh
                p.bg = Background(pdf: sha, n: i + 1)
                return p
            }
        }
        if asSection, notebook != nil {
            let secID = newID()
            let ps = pages(secID)
            let cur = pageID.flatMap { notebook?.section(of: $0) }?.id
            changeLayout({ secs in
                let at = cur.flatMap { c in secs.firstIndex { $0.id == c } }.map { $0 + 1 } ?? secs.count
                secs.insert(Section(id: secID, title: name, pages: ps.map(\.id)), at: at)
            }, pages: ps)
            flushSave()
            if let first = ps.first { show(first.id) }
            castCurrent()  // the computer needs the file before it can show the pages
            say("Added \(name) (\(ps.count) pages)")
        } else {
            let secID = newID()
            let ps = pages(secID)
            let nb = finish(Notebook(id: newID(), title: name, size: PageSize.letter.rawValue, metaT: t, created: t,
                                     layout: Layout(t: t, sections: [Section(id: secID, title: name, pages: ps.map(\.id))]),
                                     pages: Dictionary(uniqueKeysWithValues: ps.map { ($0.id, $0) })))
            store.save(nb)
            refreshLibrary()
            sync?.run()
            open(nb.id)
            say("Imported \(name) (\(ps.count) pages)")
        }
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

    /// The notebook a library card shows, for exporting it without opening.
    func exportNotebookPDF(_ id: String) -> URL? {
        guard let nb = store.load(id) else { return nil }
        let data = PDFExporter.render(pages: nb.order.compactMap { nb.pages[$0] }, title: nb.title, store: store,
                                      liveFrame: nil, outline: [])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(nb.title.replacingOccurrences(of: "/", with: "-").prefix(80)).pdf")
        return (try? data.write(to: url, options: .atomic)) != nil ? url : nil
    }
}
