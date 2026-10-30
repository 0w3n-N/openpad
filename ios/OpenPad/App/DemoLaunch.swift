#if DEBUG
import Foundation
import OpenPadCore

/// Launch arguments for the simulator test in CI (Debug builds only):
///   -openpadDemo YES             add a sample notebook with ink and a section
///   -openpadServer http://h:p    connect to this computer
///   -openpadKey <key>            with this key
///   -openpadOpen YES             open the sample notebook
@MainActor
enum DemoLaunch {
    static let defaults = UserDefaults.standard

    static func prepare(_ model: AppModel) {
        if let server = defaults.string(forKey: "openpadServer"), let key = defaults.string(forKey: "openpadKey"),
           let base = URL(string: server) {
            let link = ServerLink(base: base, key: key, name: "CI computer", alts: [])
            model.link = link
            model.store.link = link.saved
        }
        guard defaults.bool(forKey: "openpadDemo"), !model.store.library.contains(where: { $0.title == "Demo notebook" }) else { return }
        var nb = newNotebook(title: "Demo notebook", size: .letter, section: "Kinematics", paper: "lines")
        nb.folder = "2025 Fall/ECE 210"
        let pid = nb.order[0]
        var wave: [[Double]] = []
        for i in 0...80 {
            let x: Double = 120 + Double(i) * 9
            let y: Double = 400 + sin(Double(i) / 8) * 90
            let p: Double = 0.3 + Double(i % 20) / 40
            wave.append([x, y, p])
        }
        var squiggle: [[Double]] = []
        for i in 0...40 {
            let x: Double = 150 + Double(i) * 6
            let y: Double = 180 + sin(Double(i)) * 14
            squiggle.append([x, y, 0.5])
        }
        let axes: [[Double]] = [[110, 260, 0.5], [110, 540, 0.5], [110, 540, 0.5], [880, 540, 0.5]]
        let marker: [[Double]] = [[140, 180, 0.5], [420, 180, 0.5]]
        // A sine wave, axes and a highlighted word-like squiggle.
        let strokes: [Stroke] = [
            Stroke(id: newID(), z: nextZ(), tool: "pen", color: "#1f5fd6", width: 4, pts: wave),
            Stroke(id: newID(), z: nextZ(), tool: "pen", color: "#111111", width: 3, pts: axes),
            Stroke(id: newID(), z: nextZ(), tool: "hl", color: "#ffd400", width: 22, pts: marker),
            Stroke(id: newID(), z: nextZ(), tool: "pen", color: "#d62f2f", width: 3.5, pts: squiggle),
        ]
        nb.pages[pid]?.strokes = strokes
        let sec2 = newID()
        let p2 = blankPage(section: sec2, size: .letter, paper: "eng")
        nb.pages[p2.id] = p2
        nb.layout.sections.append(Section(id: sec2, title: "Waves", pages: [p2.id]))
        nb.layout.t = nowMS()
        model.store.save(finish(nb))
        model.refreshLibrary()
    }

    static func open(_ model: AppModel) {
        if defaults.bool(forKey: "openpadOffloadAll") {
            // Wait for the first sync, then offload everything the computer has.
            Task {
                for _ in 0..<60 where model.syncState != .ok { try? await Task.sleep(nanoseconds: 500_000_000) }
                model.enforceStorageLimit(force: true)
            }
        }
        guard defaults.bool(forKey: "openpadOpen"), let entry = model.store.library.first(where: { $0.title == "Demo notebook" }) else { return }
        Task {
            // An offloaded notebook downloads once the computer is reachable.
            for _ in 0..<40 where entry.offloaded && model.syncState != .ok { try? await Task.sleep(nanoseconds: 500_000_000) }
            model.open(entry.id)
            guard defaults.bool(forKey: "openpadDrawTest") else { return }
            // A stroke "drawn" here once the notebook is live on the computer.
            for _ in 0..<60 where !model.liveReady { try? await Task.sleep(nanoseconds: 500_000_000) }
            guard let page = model.pageID else { return }
            var pts: [[Double]] = []
            for i in 0...30 {
                let x: Double = 200 + Double(i) * 12
                let y: Double = 700 + cos(Double(i) / 3) * 40
                pts.append([x, y, 0.6])
            }
            let s = Stroke(id: "cistroke01", z: nextZ(), tool: "pen", color: "#30a46c", width: 5, pts: pts)
            model.localStrokes(page: page, added: [s], removed: [])
            if defaults.bool(forKey: "openpadInkTest") { model.canvas?.runInkTest() }
        }
    }
}
#endif
