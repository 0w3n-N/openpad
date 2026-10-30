import Foundation

// The geometry of ink, the same as web/ink.js and web/editor.js: pressure,
// hit testing, bounds, shapes and the lasso. Points are [x, y, pressure] in
// page units (pages are 1000 units wide).

public enum Ink {
    /// The colors of the toolbar (web/ink.js COLORS).
    public static let colors = ["#111111", "#1f5fd6", "#d62f2f", "#1d9a4b", "#e07b00", "#7b3fd1", "#ffffff"]
    /// Pen widths: fine, medium, bold.
    public static let widths: [Double] = [2, 3.5, 6.5]
    /// The highlighter's width for each pen width.
    public static func highlighterWidth(_ width: Double) -> Double {
        switch width {
        case 2: return 14
        case 6.5: return 34
        default: return 22
        }
    }
    /// The highlighter's color when the pen color is the default black.
    public static let highlighterYellow = "#ffd400"

    /// The stored pressure value that gives exactly the base width.
    public static let neutralPressure = 0.65 / 1.15

    /// Width multiplier from a stored pressure value.
    public static func pressureWidth(_ base: Double, _ p: Double?) -> Double {
        base * (0.35 + 1.15 * min(1, max(0, p ?? 0.5)))
    }

    /// Raw Pencil pressure (0...1) to the stored value. Sensitivity 0 draws an
    /// even line, 1 uses the full range. Smoothed along the stroke so small
    /// wobbles in pressure don't make the line lumpy.
    public static func shapePressure(_ raw: Double, sensitivity: Double, previous: Double?) -> Double {
        let p = neutralPressure + (min(1, max(0, raw)) - neutralPressure) * sensitivity
        guard let previous else { return p }
        return previous + (p - previous) * 0.35
    }

    public static func round2(_ v: Double) -> Double { (v * 100).rounded() / 100 }
    public static func round3(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }

    // MARK: hit testing

    private static func segmentDistance2(_ px: Double, _ py: Double, _ ax: Double, _ ay: Double, _ bx: Double, _ by: Double) -> Double {
        let dx = bx - ax, dy = by - ay
        let l2 = dx * dx + dy * dy
        var t = l2 > 0 ? ((px - ax) * dx + (py - ay) * dy) / l2 : 0
        t = max(0, min(1, t))
        let x = ax + t * dx - px, y = ay + t * dy - py
        return x * x + y * y
    }

    /// Whether a circle of radius r at (x, y) touches the stroke.
    public static func hit(_ s: Stroke, x: Double, y: Double, r: Double) -> Bool {
        let p = s.pts.filter { $0.count >= 2 }
        guard let first = p.first else { return false }
        let rr = r + s.width / 2
        let r2 = rr * rr
        if p.count == 1 { return (first[0] - x) * (first[0] - x) + (first[1] - y) * (first[1] - y) <= r2 }
        for i in 1..<p.count where segmentDistance2(x, y, p[i - 1][0], p[i - 1][1], p[i][0], p[i][1]) <= r2 {
            return true
        }
        return false
    }

    /// The stroke's bounds, with its width as margin: (minX, minY, maxX, maxY).
    public static func bounds(_ s: Stroke) -> (Double, Double, Double, Double) {
        var x0 = Double.infinity, y0 = Double.infinity, x1 = -Double.infinity, y1 = -Double.infinity
        for q in s.pts where q.count >= 2 {
            x0 = min(x0, q[0]); y0 = min(y0, q[1]); x1 = max(x1, q[0]); y1 = max(y1, q[1])
        }
        guard x0 <= x1 else { return (0, 0, 0, 0) }
        // Pressure can make a line up to 1.5x its base width.
        let m = s.width * 1.5
        return (x0 - m, y0 - m, x1 + m, y1 + m)
    }

    /// Ray casting, like web/editor.js pointInPoly.
    public static func inside(_ x: Double, _ y: Double, polygon poly: [[Double]]) -> Bool {
        var result = false
        var j = poly.count - 1
        for i in poly.indices {
            let xi = poly[i][0], yi = poly[i][1], xj = poly[j][0], yj = poly[j][1]
            if (yi > y) != (yj > y) && x < (xj - xi) * (y - yi) / (yj - yi) + xi { result.toggle() }
            j = i
        }
        return result
    }

    /// Strokes the lasso holds: at least half their points inside it.
    public static func lassoed(_ s: Stroke, polygon: [[Double]]) -> Bool {
        let p = s.pts.filter { $0.count >= 2 }
        let n = p.filter { inside($0[0], $0[1], polygon: polygon) }.count
        return !p.isEmpty && Double(n) >= max(1, Double(p.count) * 0.5)
    }

    // MARK: shapes

    public enum Shape: String, CaseIterable, Sendable {
        case line, arrow, rect, ellipse, axes
    }

    /// A straight line from a to b, as evenly spaced points.
    public static func line(_ a: [Double], _ b: [Double]) -> [[Double]] {
        let n = max(2, Int((hypot(b[0] - a[0], b[1] - a[1]) / 12).rounded(.up)))
        return (0...n).map { i in
            let t = Double(i) / Double(n)
            return [round2(a[0] + (b[0] - a[0]) * t), round2(a[1] + (b[1] - a[1]) * t), neutralPressure]
        }
    }

    /// Shapes are ordinary strokes, so they sync, erase and export like ink.
    /// Corners repeat their point so the stroke stays sharp there.
    public static func shapePoints(_ kind: Shape, from a: [Double], to b: [Double]) -> [[Double]] {
        let x0 = a[0], y0 = a[1], x1 = b[0], y1 = b[1]
        func P(_ x: Double, _ y: Double) -> [Double] { [round2(x), round2(y), neutralPressure] }
        switch kind {
        case .line:
            return line(a, b)
        case .arrow:
            let ang = atan2(y1 - y0, x1 - x0)
            let len = min(28, hypot(x1 - x0, y1 - y0) * 0.35)
            let h1 = P(x1 - len * cos(ang - 0.45), y1 - len * sin(ang - 0.45))
            let h2 = P(x1 - len * cos(ang + 0.45), y1 - len * sin(ang + 0.45))
            return line(a, b) + [h1, P(x1, y1), h2]
        case .rect:
            return [P(x0, y0), P(x1, y0), P(x1, y0), P(x1, y1), P(x1, y1), P(x0, y1), P(x0, y1), P(x0, y0), P(x0, y0)]
        case .ellipse:
            let cx = (x0 + x1) / 2, cy = (y0 + y1) / 2, rx = abs(x1 - x0) / 2, ry = abs(y1 - y0) / 2
            let n = max(24, min(96, Int(((rx + ry) / 3).rounded())))
            return (0...(n + 1)).map { i in
                let t = Double(i) / Double(n) * .pi * 2
                return P(cx + rx * cos(t), cy + ry * sin(t))
            }
        case .axes:
            // x and y axes crossing at the start point, with arrowheads.
            let dx: Double = x1 - x0 == 0 ? 1 : (x1 > x0 ? 1 : -1)
            let dy: Double = y1 - y0 == 0 ? -1 : (y1 > y0 ? 1 : -1)
            let ah = 12.0
            let xa = [P(x0 - 20 * dx, y0), P(x1, y0), P(x1 - ah * dx, y0 - ah * 0.6), P(x1, y0), P(x1 - ah * dx, y0 + ah * 0.6), P(x1, y0)]
            let ya = [P(x0, y0), P(x0, y0 - 20 * dy), P(x0, y0), P(x0, y1), P(x0 - ah * 0.6, y1 - ah * dy), P(x0, y1), P(x0 + ah * 0.6, y1 - ah * dy)]
            return xa + ya
        }
    }

    /// The same strokes under new ids (removed ids stay removed everywhere).
    public static func reid(_ strokes: [Stroke]) -> [Stroke] {
        strokes.map { s in
            var c = s
            c.id = newID()
            return c
        }
    }
}
