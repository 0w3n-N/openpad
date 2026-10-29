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
/// comes back; files pages show go wherever they're missing; deletions carry
/// over; changed sections are rebuilt as readable PDFs on the computer.
@MainActor
final class SyncEngine {
    let link: ServerLink
    let store: Store
    var onState: ((SyncState) -> Void)?
    var onChanged: ((String, Notebook?) -> Void)?  // a notebook changed (nil: deleted)
    var isBusy: () -> Bool = { false }  // the pen is down: readable PDFs wait

    private var running = false
    private var again = false
    private var pdfDue: [String: Date] = [:]

    init(link: ServerLink, store: Store) {
        self.link = link
        self.store = store
    }

    func run() {
        if running {
            again = true
            return
        }
        running = true
        Task {
            defer { running = false }
            repeat {
                again = false
                onState?(.syncing)
                do {
                    try await pass()
                    onState?(.ok)
                } catch let e as HTTPError where e.status == 403 {
                    onState?(.unpaired)
                    return
                } catch {
                    onState?(.offline(error.localizedDescription))
                    return
                }
            } while again
        }
    }

    private func pass() async throws {
        let remote = try await link.json("/api/sync")
        let remoteList = (remote["notebooks"] as? [[String: Any]]) ?? []
        let remoteDeleted = (remote["deleted"] as? [String: Any]) ?? [:]
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
            guard let nb = store.load(entry.id) else { continue }
            let d = digest(nb)
            if remoteDigest[entry.id] == d {
                if entry.dirty { store.markSynced(entry.id, digest: d) }
                try await syncAssets(nb, missing: [])
                continue
            }
            try await push(nb, digest: d)
        }
        for (id, d) in remoteDigest where store.index[id] == nil {
            let data = try await link.call("/api/sync/nb/\(id)")
            guard let nb = try? JSONDecoder().decode(Notebook.self, from: data) else { continue }
            store.save(nb, dirty: false, synced: d)
            try await syncAssets(nb, missing: [])
            onChanged?(id, nb)
            queuePDF(id)
        }
        try await buildPDFs(force: false)
    }

    /// Send one notebook; merge back what the computer had that we didn't.
    func push(_ nb: Notebook, digest d: String? = nil) async throws {
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
        queuePDF(nb.id)
    }

    /// Upload files the computer lacks; download ones this iPad lacks.
    private func syncAssets(_ nb: Notebook, missing: [String]) async throws {
        for sha in missing {
            if let data = store.assetData(sha) {
                _ = try await link.call("/api/asset/\(sha)", method: "PUT", body: data,
                                        headers: ["Content-Type": "application/octet-stream"])
            }
        }
        for sha in nb.assets where !missing.contains(sha) && !store.hasAsset(sha) {
            if let data = try? await link.call("/api/asset/\(sha)") {
                _ = store.putAsset(data, expected: sha)
            }
        }
    }

    // MARK: readable PDFs on the computer

    /// Rebuild changed sections as PDFs in the computer's Documents/OpenPad,
    /// a little after the last change.
    func queuePDF(_ id: String, after seconds: TimeInterval = 45) {
        let due = Date().addingTimeInterval(seconds)
        pdfDue[id] = min(pdfDue[id] ?? due, due)
    }

    func buildPDFs(force: Bool) async throws {
        for (id, due) in pdfDue {
            if !force && (due > Date() || isBusy()) { continue }
            pdfDue[id] = nil
            guard let nb = store.load(id) else { continue }
            let done = store.index[id]?.pdfDone ?? [:]
            for sec in nb.layout.sections where !sec.pages.isEmpty {
                let d = sectionDigest(nb, sec)
                if done[sec.id] == d { continue }
                if !force && isBusy() {
                    queuePDF(id, after: 5)
                    break
                }
                let pages = sec.pages.compactMap { nb.pages[$0] }
                let data = PDFExporter.render(pages: pages, title: "\(nb.title) – \(sec.title)", store: store)
                _ = try await link.call("/api/sync/pdf/\(id)/\(sec.id)", method: "PUT", body: data,
                                        headers: ["Content-Type": "application/pdf"])
                store.setPDFDone(id, section: sec.id, digest: d)
            }
        }
    }

    private func sectionDigest(_ nb: Notebook, _ sec: Section) -> String {
        sec.title + "|" + sec.pages.compactMap { id -> String? in
            guard let p = nb.pages[id] else { return nil }
            return "\(id):\(p.t):\(p.strokes.count):\(p.strokes.reduce(0) { $0 + $1.pts.count }):\(p.gone.count)"
        }.joined(separator: ",")
    }
}
