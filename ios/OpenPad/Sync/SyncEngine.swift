import Foundation
import OpenPadCore

enum SyncState: Equatable {
    case none  // not connected to a computer
    case syncing
    case ok
    case offline(String)
    case unpaired  // the computer's key changed
}

/// Syncs every notebook with the computer, both ways (the same steps as
/// web/link.js): notebooks whose digests differ are sent and the merged copy
/// comes back; files go wherever they're missing; deletions carry over;
/// changed sections are rebuilt as readable PDFs in the computer's sync folder.
/// Offloaded notebooks only get their outline refreshed.
@MainActor
final class SyncEngine {
    let link: ServerLink
    let store: Store
    var onState: ((SyncState) -> Void)?
    var onChanged: ((String, Notebook?) -> Void)?  // a notebook changed (nil: deleted)
    var onPassDone: (() -> Void)?
    var isBusy: () -> Bool = { false }  // the pen is down: readable PDFs wait

    private(set) var running = false
    private var again = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var pdfDue: [String: Date] = [:]
    private var serverPDFs: [String: [String: String]] = [:]  // nb -> section -> digest the computer has
    private(set) var lastError: String?

    init(link: ServerLink, store: Store) {
        self.link = link
        self.store = store
    }

    /// Start a sync (or one more pass after the running one).
    func run() {
        if running {
            again = true
            return
        }
        running = true
        Task {
            repeat {
                again = false
                onState?(.syncing)
                do {
                    try await pass()
                    lastError = nil
                    onState?(.ok)
                    onPassDone?()
                } catch let e as HTTPError where e.status == 403 {
                    lastError = e.localizedDescription
                    onState?(.unpaired)
                    break
                } catch {
                    lastError = error.localizedDescription
                    onState?(.offline(error.localizedDescription))
                    break
                }
            } while again
            running = false
            waiters.forEach { $0.resume() }
            waiters.removeAll()
        }
    }

    /// Run a sync and wait for it to finish.
    func runAndWait() async {
        run()
        await withCheckedContinuation { c in waiters.append(c) }
    }

    /// The computer's Sync button: everything, readable PDFs included.
    /// Returns how many notebooks this iPad has.
    func syncAll() async throws -> Int {
        await runAndWait()
        if let lastError { throw ConnectError(message: lastError) }
        for e in store.library where !e.offloaded { queuePDF(e.id, after: 0) }
        try await buildPDFs(force: true)
        return store.library.count
    }

    private func pass() async throws {
        let remote = try await link.json("/api/sync")
        let remoteList = (remote["notebooks"] as? [[String: Any]]) ?? []
        let remoteDeleted = (remote["deleted"] as? [String: Any]) ?? [:]
        serverPDFs = (remote["pdfs"] as? [String: [String: String]]) ?? [:]
        let remoteDigest = Dictionary(remoteList.compactMap { n -> (String, String)? in
            guard let id = n["id"] as? String, let d = n["d"] as? String else { return nil }
            return (id, d)
        }, uniquingKeysWith: { a, _ in a })

        for entry in Array(store.index.values) {
            if let t = entry.deleted {
                let body = try JSONSerialization.data(withJSONObject: ["id": entry.id, "t": t])
                _ = try await link.call("/api/sync/delete", method: "POST", body: body, headers: ["Content-Type": "application/json"])
                store.forget(entry.id)
                continue
            }
            if remoteDeleted[entry.id] != nil {
                store.forget(entry.id)  // deleted on another device: deletes win
                onChanged?(entry.id, nil)
                continue
            }
            if entry.offloaded {
                // Only the outline is here: refresh it if the computer's copy changed.
                if let d = remoteDigest[entry.id], d != entry.synced {
                    let data = try await link.call("/api/sync/nb/\(entry.id)")
                    if let nb = try? JSONDecoder().decode(Notebook.self, from: data) {
                        store.saveOutline(nb, synced: d)
                        onChanged?(entry.id, nb)
                    }
                }
                continue
            }
            // Unchanged on both sides: nothing to load or send.
            if !entry.dirty, entry.filesSynced, let d = remoteDigest[entry.id], d == entry.synced { continue }
            guard let nb = store.load(entry.id) else { continue }
            let d = digest(nb)
            if remoteDigest[entry.id] == d {
                if entry.dirty || !entry.filesSynced {
                    try await syncAssets(nb, missing: nil)
                    // Unless it changed while the files went across.
                    if let latest = store.load(entry.id), digest(latest) == d {
                        store.markSynced(entry.id, digest: d)
                        store.update(entry.id) { $0.filesSynced = true }
                    }
                }
                continue
            }
            try await push(nb, digest: d)
        }
        for (id, d) in remoteDigest where store.index[id] == nil {
            let data = try await link.call("/api/sync/nb/\(id)")
            guard let nb = try? JSONDecoder().decode(Notebook.self, from: data) else { continue }
            store.save(nb, dirty: false, synced: d)
            try await syncAssets(nb, missing: [])
            if store.index[id]?.dirty == false { store.update(id) { $0.filesSynced = true } }
            store.refreshThumbnails(nb)
            onChanged?(id, nb)
        }
        // Sections the computer has no current PDF of.
        for e in store.library where !e.offloaded {
            if serverPDFs[e.id] == nil || (serverPDFs[e.id]?.count ?? 0) < e.sections { queuePDF(e.id, after: 30) }
        }
        try await buildPDFs(force: false)
    }

    /// Send one notebook; merge back what the computer had that we didn't.
    func push(_ nb: Notebook, digest d: String? = nil) async throws {
        guard store.index[nb.id]?.offloaded != true else { return }
        let d = d ?? digest(nb)
        let body = try JSONEncoder().encode(nb)
        let res = try await link.json("/api/sync/nb", method: "POST", body: body,
                                      headers: ["Content-Type": "application/json", "X-OpenPad-Digest": d])
        if res["deleted"] != nil {
            store.forget(nb.id)
            onChanged?(nb.id, nil)
            return
        }
        let serverDigest = res["d"] as? String ?? ""
        var result = nb
        if let obj = res["nb"], !(obj is NSNull), let theirs = decodeJSON(Notebook.self, from: obj) {
            // Merge into the latest local copy: it may have changed meanwhile.
            let latest = store.load(nb.id) ?? nb
            result = merge(latest, theirs)
            store.save(result, dirty: digest(result) != serverDigest, synced: serverDigest)
            onChanged?(nb.id, result)
        } else if digest(store.load(nb.id) ?? nb) == d {
            store.markSynced(nb.id, digest: serverDigest)
        }
        try await syncAssets(result, missing: (res["missing"] as? [String]) ?? [])
        if store.index[nb.id]?.dirty == false { store.update(nb.id) { $0.filesSynced = true } }
        queuePDF(nb.id)
    }

    /// Upload files the computer lacks (nil: ask it), download ones this iPad lacks.
    private func syncAssets(_ nb: Notebook, missing: [String]?) async throws {
        var missing = missing
        if missing == nil {
            // Ask by re-sending the digest-matching notebook's file list cheaply:
            // a HEAD-like check per file.
            missing = []
            for sha in nb.assets where store.hasAsset(sha) {
                if (try? await link.call("/api/asset/\(sha)", method: "HEAD")) == nil { missing?.append(sha) }
            }
        }
        for sha in missing ?? [] {
            if let data = store.assetData(sha) {
                _ = try await link.call("/api/asset/\(sha)", method: "PUT", body: data,
                                        headers: ["Content-Type": "application/octet-stream"])
            }
        }
        for sha in nb.assets where !(missing ?? []).contains(sha) && !store.hasAsset(sha) {
            if let data = try? await link.call("/api/asset/\(sha)") {
                _ = store.putAsset(data, expected: sha)
            }
        }
    }

    /// Download an offloaded notebook (to open it).
    func download(_ id: String) async throws -> Notebook {
        let data = try await link.call("/api/sync/nb/\(id)")
        let nb = try JSONDecoder().decode(Notebook.self, from: data)
        let d = digest(nb)
        for sha in nb.assets where !store.hasAsset(sha) {
            let file = try await link.call("/api/asset/\(sha)")
            guard store.putAsset(file, expected: sha) else { throw ConnectError(message: "A file of this notebook didn't download correctly.") }
        }
        store.save(nb, dirty: false, synced: d)
        store.update(id) { $0.filesSynced = true }
        return nb
    }

    // MARK: readable PDFs on the computer

    /// Rebuild changed sections as PDFs in the computer's sync folder, a
    /// little after the last change.
    func queuePDF(_ id: String, after seconds: TimeInterval = 45) {
        let due = Date().addingTimeInterval(seconds)
        pdfDue[id] = min(pdfDue[id] ?? due, due)
    }

    func buildPDFs(force: Bool) async throws {
        for (id, due) in pdfDue {
            if !force && (due > Date() || isBusy()) { continue }
            pdfDue[id] = nil
            guard store.index[id]?.offloaded != true, let nb = store.load(id) else { continue }
            for sec in nb.layout.sections where !sec.pages.isEmpty {
                let d = sectionDigest(nb, sec)
                if serverPDFs[id]?[sec.id] == d { continue }
                if !force && isBusy() {
                    queuePDF(id, after: 5)
                    break
                }
                let pages = sec.pages.compactMap { nb.pages[$0] }
                let data = PDFExporter.render(pages: pages, title: "\(nb.title) – \(sec.title)", store: store)
                _ = try await link.call("/api/sync/pdf/\(id)/\(sec.id)", method: "PUT", body: data,
                                        headers: ["Content-Type": "application/pdf", "X-OpenPad-Digest": d])
                serverPDFs[id, default: [:]][sec.id] = d
            }
        }
    }

    /// Same as web/link.js sectionDigest: changes when the section's content does.
    private func sectionDigest(_ nb: Notebook, _ sec: Section) -> String {
        let text = nb.title + "|" + sec.title + "|" + sec.pages.compactMap { id -> String? in
            guard let p = nb.pages[id] else { return nil }
            return "\(id):\(p.t):\(p.strokes.count):\(p.strokes.reduce(0) { $0 + $1.pts.count }):\(p.gone.count)"
        }.joined(separator: ",")
        return String(sha256Hex(Array(text.utf8)).prefix(32))
    }
}
