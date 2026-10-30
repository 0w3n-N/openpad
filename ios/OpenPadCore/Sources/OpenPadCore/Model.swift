import Foundation

/// Page coordinates: every page is 1000 units wide.
public let pageWidth: Double = 1000

public enum PageSize: String, CaseIterable, Codable, Sendable {
    case letter, a4, wide

    /// Height of a 1000-wide page, and the PDF page size in points.
    public var height: Double {
        switch self {
        case .letter: return 1294.12
        case .a4: return 1414.29
        case .wide: return 562.5
        }
    }

    public var points: [Double] {
        switch self {
        case .letter: return [612, 792]
        case .a4: return [595.28, 841.89]
        case .wide: return [960, 540]
        }
    }

    public var label: String {
        switch self {
        case .letter: return "Letter"
        case .a4: return "A4"
        case .wide: return "Widescreen"
        }
    }
}

public let papers = ["blank", "lines", "grid", "dots", "eng"]

/// One ink stroke. Points are [x, y, pressure] in page units; pressure is
/// already shaped, so width = base width * (0.35 + 1.15 * pressure).
public struct Stroke: Codable, Equatable, Sendable {
    public var id: String
    public var z: Double
    public var tool: String  // "pen" or "hl" (highlighter)
    public var color: String  // #rrggbb
    public var width: Double
    public var pts: [[Double]]
    public var by: String?  // set by the computer for guests' ink

    public init(id: String, z: Double, tool: String, color: String, width: Double, pts: [[Double]], by: String? = nil) {
        self.id = id
        self.z = z
        self.tool = tool
        self.color = color
        self.width = width
        self.pts = pts
        self.by = by
    }

    enum CodingKeys: String, CodingKey { case id, z, tool, color, width, pts, by }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        z = try c.decodeIfPresent(Double.self, forKey: .z) ?? 0
        tool = try c.decodeIfPresent(String.self, forKey: .tool) ?? "pen"
        color = try c.decodeIfPresent(String.self, forKey: .color) ?? "#111111"
        width = try c.decodeIfPresent(Double.self, forKey: .width) ?? 3.5
        pts = try c.decodeIfPresent([[Double]].self, forKey: .pts) ?? []
        by = try c.decodeIfPresent(String.self, forKey: .by)
    }
}

/// A page background: a PDF page, an image (a frozen desktop window) or a live window.
public struct Background: Codable, Equatable, Sendable {
    public var pdf: String?
    public var n: Int?
    public var img: String?
    public var live: Bool?

    public init(pdf: String? = nil, n: Int? = nil, img: String? = nil, live: Bool? = nil) {
        self.pdf = pdf
        self.n = n
        self.img = img
        self.live = live
    }

    /// The file it shows, if any (a SHA-256 of the file's bytes).
    public var asset: String? { pdf ?? img }
}

public struct Page: Codable, Equatable, Sendable {
    public var id: String
    public var t: Int64
    public var sec: String
    public var w: Double
    public var h: Double
    public var paper: String
    public var bg: Background?
    public var pt: [Double]
    public var title: String  // optional page title ("" for none)
    public var strokes: [Stroke]
    public var gone: [String]

    public init(id: String, t: Int64, sec: String, h: Double, paper: String, bg: Background? = nil, pt: [Double],
                title: String = "", strokes: [Stroke] = [], gone: [String] = []) {
        self.id = id
        self.t = t
        self.sec = sec
        self.w = pageWidth
        self.h = h
        self.paper = paper
        self.bg = bg
        self.pt = pt
        self.title = title
        self.strokes = strokes
        self.gone = gone
    }

    enum CodingKeys: String, CodingKey { case id, t, sec, w, h, paper, bg, pt, title, strokes, gone }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        t = try decodeStamp(c, .t)
        sec = try c.decodeIfPresent(String.self, forKey: .sec) ?? ""
        w = pageWidth
        h = try c.decodeIfPresent(Double.self, forKey: .h) ?? PageSize.letter.height
        paper = try c.decodeIfPresent(String.self, forKey: .paper) ?? "blank"
        bg = try c.decodeIfPresent(Background.self, forKey: .bg)
        pt = try c.decodeIfPresent([Double].self, forKey: .pt) ?? [612, 792]
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        strokes = try c.decodeIfPresent([Stroke].self, forKey: .strokes) ?? []
        gone = try c.decodeIfPresent([String].self, forKey: .gone) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(t, forKey: .t)
        try c.encode(sec, forKey: .sec)
        try c.encode(w, forKey: .w)
        try c.encode(h, forKey: .h)
        try c.encode(paper, forKey: .paper)
        try c.encode(bg, forKey: .bg)  // null when there's none
        try c.encode(pt, forKey: .pt)
        try c.encode(title, forKey: .title)
        try c.encode(strokes, forKey: .strokes)
        try c.encode(gone, forKey: .gone)
    }

    /// The page's settings without its ink (for structural edits).
    public var metaOnly: Page {
        var p = self
        p.strokes = []
        p.gone = []
        return p
    }
}

public struct Section: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var pages: [String]
    public var color: String?  // #rrggbb tab color, if set

    public init(id: String, title: String, pages: [String], color: String? = nil) {
        self.id = id
        self.title = title
        self.pages = pages
        self.color = color
    }
}

public struct Layout: Codable, Equatable, Sendable {
    public var t: Int64
    public var sections: [Section]

    public init(t: Int64, sections: [Section]) {
        self.t = t
        self.sections = sections
    }

    enum CodingKeys: String, CodingKey { case t, sections }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        t = try decodeStamp(c, .t)
        sections = try c.decodeIfPresent([Section].self, forKey: .sections) ?? []
    }
}

public struct Notebook: Codable, Equatable, Sendable, Identifiable {
    public var v: Int = 1
    public var id: String
    public var title: String
    public var size: String
    public var folder: String  // where it's filed, e.g. "2025 Fall" ("" = top level)
    public var metaT: Int64
    public var created: Int64
    public var layout: Layout
    public var goneP: [String]
    public var pages: [String: Page]

    public init(id: String, title: String, size: String, folder: String = "", metaT: Int64, created: Int64, layout: Layout,
                goneP: [String] = [], pages: [String: Page]) {
        self.id = id
        self.title = title
        self.size = size
        self.folder = folder
        self.metaT = metaT
        self.created = created
        self.layout = layout
        self.goneP = goneP
        self.pages = pages
    }

    enum CodingKeys: String, CodingKey { case v, id, title, size, folder, metaT, created, layout, goneP, pages }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Untitled notebook"
        let s = try c.decodeIfPresent(String.self, forKey: .size) ?? "letter"
        size = PageSize(rawValue: s) == nil ? "letter" : s
        folder = try c.decodeIfPresent(String.self, forKey: .folder) ?? ""
        metaT = try decodeStamp(c, .metaT)
        created = try decodeStamp(c, .created)
        layout = try c.decodeIfPresent(Layout.self, forKey: .layout) ?? Layout(t: 0, sections: [])
        goneP = try c.decodeIfPresent([String].self, forKey: .goneP) ?? []
        var pages = try c.decodeIfPresent([String: Page].self, forKey: .pages) ?? [:]
        for (key, page) in pages where page.id != key { pages[key]?.id = key }
        self.pages = pages
    }

    public var pageSize: PageSize { PageSize(rawValue: size) ?? .letter }

    /// Page ids in reading order.
    public var order: [String] { layout.sections.flatMap { $0.pages } }

    public func section(of pageID: String) -> Section? {
        layout.sections.first { $0.pages.contains(pageID) }
    }

    public var modified: Int64 {
        max(metaT, layout.t, pages.values.map(\.t).max() ?? 0)
    }

    /// Files (PDFs, images) the pages show.
    public var assets: Set<String> {
        Set(pages.values.compactMap { $0.bg?.asset })
    }
}

/// Millisecond timestamps arrive as JSON integers (or, leniently, floats).
func decodeStamp<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) throws -> Int64 {
    if let v = try? c.decodeIfPresent(Int64.self, forKey: key) { return v }
    if let d = try? c.decodeIfPresent(Double.self, forKey: key), d.isFinite { return Int64(d) }
    return 0
}

// MARK: - building

public func newID() -> String {
    var g = SystemRandomNumberGenerator()
    return (0..<6).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &g)) }.joined()
}

public func nowMS() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

public func blankPage(section: String, size: PageSize, paper: String, t: Int64 = nowMS()) -> Page {
    Page(id: newID(), t: t, sec: section, h: size.height, paper: paper, pt: size.points)
}

public func newNotebook(title: String, size: PageSize, section: String = "Notes", paper: String = "lines") -> Notebook {
    let t = nowMS()
    let sec = newID()
    let page = blankPage(section: sec, size: size, paper: paper, t: t)
    return finish(Notebook(id: newID(), title: title, size: size.rawValue, metaT: t, created: t,
                           layout: Layout(t: t, sections: [Section(id: sec, title: section, pages: [page.id])]),
                           pages: [page.id: page]))
}

private var zCounter = 0
/// Stacking order for a new stroke: later strokes draw on top.
public func nextZ() -> Double {
    zCounter = (zCounter + 1) % 1000
    return Double(nowMS()) * 1000 + Double(zCounter)
}
