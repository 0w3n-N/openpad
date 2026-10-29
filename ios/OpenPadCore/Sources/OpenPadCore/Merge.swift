import Foundation

// The merge rules of openpad/notebook.py (read its docstring first), so the
// iPad, the computer and the web app always agree:
//   * strokes are only added or removed; a page keeps the ids it removed
//     ("gone") and merging drops them everywhere;
//   * page settings, titles and the section layout are last-writer-wins by
//     their millisecond timestamps;
//   * deleted pages stay deleted ("goneP").
// Tests/merge_vectors.json (made from the Python code) checks this file.

/// Strings compared by Unicode code points, like Python and (for the text
/// OpenPad stores) JavaScript. Swift's own < compares canonical forms.
@inline(__always)
func codepointLess(_ a: String, _ b: String) -> Bool {
    a.unicodeScalars.lexicographicallyPrecedes(b.unicodeScalars)
}

func compare(_ a: (Int64, String), _ b: (Int64, String)) -> Int {
    if a.0 != b.0 { return a.0 < b.0 ? -1 : 1 }
    if a.1 == b.1 { return 0 }
    return codepointLess(a.1, b.1) ? -1 : 1
}

func metaKey(_ p: Page) -> (Int64, String) {
    let bg = p.bg
    let asset = bg?.pdf ?? bg?.img ?? ((bg?.live ?? false) ? "live" : "")
    let n = bg?.n.map { String($0) } ?? ""
    return (p.t, "\(p.sec)|\(p.paper)|\(asset)|\(n)")
}

func layoutKey(_ l: Layout) -> (Int64, String) {
    (l.t, l.sections.map { "\($0.id):\($0.title):\($0.pages.joined(separator: ","))" }.joined(separator: "|"))
}

func sortedIDs(_ ids: Set<String>) -> [String] {
    ids.sorted(by: codepointLess)
}

func byZ(_ a: Stroke, _ b: Stroke) -> Bool {
    a.z != b.z ? a.z < b.z : codepointLess(a.id, b.id)
}

func mergePage(_ a: Page, _ b: Page) -> Page {
    let meta = compare(metaKey(a), metaKey(b)) >= 0 ? a : b
    let gone = Set(a.gone).union(b.gone)
    var strokes: [String: Stroke] = [:]
    for s in a.strokes + b.strokes where !gone.contains(s.id) {
        if let old = strokes[s.id], old.pts.count >= s.pts.count { continue }  // mid-stroke copies: the longer one
        strokes[s.id] = s
    }
    var out = meta
    out.id = a.id
    out.strokes = strokes.values.sorted(by: byZ)
    out.gone = sortedIDs(gone)
    return out
}

/// Merge two copies of the same notebook. Order doesn't matter, and merging a
/// copy into itself changes nothing.
public func merge(_ a: Notebook, _ b: Notebook) -> Notebook {
    let aMeta = (a.metaT, a.title, a.size), bMeta = (b.metaT, b.title, b.size)
    let metaFromA: Bool = {
        if aMeta.0 != bMeta.0 { return aMeta.0 > bMeta.0 }
        if aMeta.1 != bMeta.1 { return !codepointLess(aMeta.1, bMeta.1) }
        return !codepointLess(aMeta.2, bMeta.2)
    }()
    let meta = metaFromA ? a : b
    let created = [a.created, b.created].filter { $0 != 0 }
    let goneP = Set(a.goneP).union(b.goneP)
    var pages: [String: Page] = [:]
    for id in Set(a.pages.keys).union(b.pages.keys) where !goneP.contains(id) {
        switch (a.pages[id], b.pages[id]) {
        case let (pa?, pb?): pages[id] = mergePage(pa, pb)
        case let (pa?, nil): pages[id] = pa
        case let (nil, pb?): pages[id] = pb
        default: break
        }
    }
    var out = Notebook(id: a.id, title: meta.title, size: meta.size, metaT: meta.metaT,
                       created: created.min() ?? 0,
                       layout: compare(layoutKey(a.layout), layoutKey(b.layout)) >= 0 ? a.layout : b.layout,
                       goneP: sortedIDs(goneP), pages: pages)
    out = finish(out)
    return out
}

/// Make the layout list exactly the live pages: drop deleted or unknown ones,
/// and put pages that aren't listed (added on another device while this
/// layout was written) at the end of their section.
public func finish(_ input: Notebook) -> Notebook {
    var nb = input
    let gone = Set(nb.goneP)
    let alive = Set(nb.pages.keys).subtracting(gone)
    var seen = Set<String>()
    var sections: [Section] = nb.layout.sections.map { s in
        // Exactly as notebook.py: `seen` grows after each whole section.
        let pages = s.pages.filter { alive.contains($0) && !seen.contains($0) }
        seen.formUnion(pages)
        return Section(id: s.id, title: s.title, pages: pages)
    }
    if sections.isEmpty { sections = [Section(id: "main", title: "Notes", pages: [])] }
    for id in sortedIDs(alive.subtracting(seen)) {
        let target = sections.firstIndex { $0.id == nb.pages[id]?.sec } ?? sections.count - 1
        sections[target].pages.append(id)
    }
    nb.layout = Layout(t: nb.layout.t, sections: sections)
    for id in nb.pages.keys where !alive.contains(id) { nb.pages[id] = nil }
    return nb
}

/// Changes whenever the notebook's content does; equal for equal content.
/// openpad/notebook.py and web/model.js compute the same value.
public func digest(_ nb: Notebook) -> String {
    var parts = ["m:\(nb.metaT)", "l:\(nb.layout.t)", "g:" + nb.goneP.joined(separator: ",")]
    for id in nb.pages.keys.sorted(by: codepointLess) {
        let p = nb.pages[id]!
        let ink = p.strokes.map { "\($0.id).\($0.pts.count)" }.sorted(by: codepointLess).joined(separator: ",")
        parts.append("p:\(id):\(p.t):\(ink):\(p.gone.joined(separator: ","))")
    }
    return String(sha256Hex(Array(parts.joined(separator: "\n").utf8)).prefix(32))
}

// MARK: - live edits

/// Apply a relayed live edit (begin/pts/remove/restore) to a notebook.
/// Returns the affected page id.
@discardableResult
public func apply(_ op: LiveOp, to nb: inout Notebook) -> String? {
    switch op {
    case let .begin(pageID, stroke):
        guard var page = nb.pages[pageID], !page.gone.contains(stroke.id),
              !page.strokes.contains(where: { $0.id == stroke.id }) else { return nil }
        page.strokes.append(stroke)
        page.strokes.sort(by: byZ)
        nb.pages[pageID] = page
        return pageID
    case let .points(strokeID, pts):
        for (pid, var page) in nb.pages {
            if let i = page.strokes.firstIndex(where: { $0.id == strokeID }) {
                page.strokes[i].pts.append(contentsOf: pts)
                nb.pages[pid] = page
                return pid
            }
        }
        return nil
    case let .remove(pageID, ids):
        guard var page = nb.pages[pageID] else { return nil }
        let set = Set(ids)
        page.strokes.removeAll { set.contains($0.id) }
        page.gone = sortedIDs(Set(page.gone).union(set))
        nb.pages[pageID] = page
        return pageID
    case let .restore(pageID, strokes):
        guard var page = nb.pages[pageID] else { return nil }
        let existing = Set(page.strokes.map(\.id)), gone = Set(page.gone)
        for s in strokes where !existing.contains(s.id) && !gone.contains(s.id) { page.strokes.append(s) }
        page.strokes.sort(by: byZ)
        nb.pages[pageID] = page
        return pageID
    }
}

public enum LiveOp: Equatable {
    case begin(page: String, stroke: Stroke)
    case points(stroke: String, pts: [[Double]])
    case remove(page: String, ids: [String])
    case restore(page: String, strokes: [Stroke])
}
