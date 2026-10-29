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
        guard defaults.bool(forKey: "openpadOpen"), let entry = model.store.library.first(where: { $0.title == "Demo notebook" }) else { return }
        model.open(entry.id)
    }
}
#endif
