import OpenPadCore
import PencilKit
import UIKit

/// Converts between PencilKit strokes (what the iPad draws) and OpenPad's
/// stroke format (what's stored, synced and shown everywhere else).
///
/// Page coordinates are 1000 units wide, and the canvas uses the same units at
/// zoom 1, so locations map directly. OpenPad stores pressure as a value that
/// sets the width: width = base * (0.35 + 1.15 * p). PencilKit stores a size
/// per point, so p is recovered from the size relative to the stroke's median.
enum InkConverter {
    static let neutralPressure = 0.65 / 1.15  // gives exactly the base width

    static func pkStroke(_ s: Stroke) -> PKStroke {
        let isMarker = s.tool == "hl"
        let ink = PKInk(isMarker ? .marker : .pen, color: UIColor(hex: s.color))
        var points: [PKStrokePoint] = []
        points.reserveCapacity(s.pts.count + 1)
        for (i, p) in s.pts.enumerated() where p.count >= 2 {
            let pressure = p.count > 2 ? min(1, max(0, p[2])) : 0.5
            let w = isMarker ? s.width : max(0.3, s.width * (0.35 + 1.15 * pressure))
            points.append(PKStrokePoint(location: CGPoint(x: p[0], y: p[1]), timeOffset: Double(i) * 0.008,
                                        size: CGSize(width: w, height: w), opacity: 1, force: CGFloat(pressure),
                                        azimuth: 0, altitude: .pi / 2))
        }
        if points.count == 1, let only = points.first {
            // A dot: PencilKit needs two points to draw anything.
            points.append(PKStrokePoint(location: CGPoint(x: only.location.x + 0.01, y: only.location.y),
                                        timeOffset: 0.008, size: only.size, opacity: 1, force: only.force,
                                        azimuth: 0, altitude: .pi / 2))
        }
        // The creation date carries the stroke's stacking order and keeps
        // fingerprints of otherwise identical strokes apart.
        let path = PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSince1970: s.z / 1_000_000))
        return PKStroke(ink: ink, path: path)
    }

    /// One PencilKit stroke as an OpenPad stroke. Masked parts (pixel eraser)
    /// must already be split off (see split).
    static func stroke(from pk: PKStroke, id: String, z: Double) -> Stroke {
        let isMarker = pk.ink.inkType == .marker
        let t = pk.transform
        let scale = sqrt(abs(t.a * t.d - t.b * t.c))
        var raw: [(CGPoint, CGFloat)] = []
        for p in pk.path.interpolatedPoints(by: .distance(3)) {
            raw.append((p.location.applying(t), p.size.width * scale))
            if raw.count >= 5000 { break }
        }
        if raw.isEmpty, let p = pk.path.first { raw.append((p.location.applying(t), p.size.width * scale)) }
        let sizes = raw.map(\.1).sorted()
        let median = sizes.isEmpty ? 3.5 : max(0.3, sizes[sizes.count / 2])
        let base = isMarker ? median : median / 0.925  // the median point gets pressure 0.5
        let pts: [[Double]] = raw.map { loc, size in
            let p = isMarker ? neutralPressure : min(1, max(0, (Double(size) / Double(base) - 0.35) / 1.15))
            return [round2(Double(loc.x)), round2(Double(loc.y)), (p * 1000).rounded() / 1000]
        }
        return Stroke(id: id, z: z, tool: isMarker ? "hl" : "pen", color: pk.ink.color.hexString,
                      width: min(80, max(0.5, (Double(base) * 100).rounded() / 100)), pts: pts)
    }

    /// Strokes cut by the pixel eraser keep their whole path plus a mask.
    /// OpenPad has no masks, so each visible part becomes its own stroke.
    static func split(_ drawing: PKDrawing) -> PKDrawing? {
        guard drawing.strokes.contains(where: { $0.mask != nil }) else { return nil }
        var out: [PKStroke] = []
        for s in drawing.strokes {
            guard s.mask != nil else {
                out.append(s)
                continue
            }
            for (i, range) in s.maskedPathRanges.enumerated() {
                let pts = Array(s.path.interpolatedPoints(in: range, by: .distance(2)))
                guard pts.count >= 2 else { continue }
                let date = s.path.creationDate.addingTimeInterval(Double(i + 1) * 0.000_001)
                out.append(PKStroke(ink: s.ink, path: PKStrokePath(controlPoints: pts, creationDate: date), transform: s.transform))
            }
        }
        return PKDrawing(strokes: out)
    }

    /// Identifies a PencilKit stroke across drawing changes (they have no ids).
    static func fingerprint(_ s: PKStroke) -> String {
        let t = s.transform
        let first = s.path.first?.location ?? .zero, last = s.path.last?.location ?? .zero
        return [
            "\(s.ink.inkType.rawValue)", s.ink.color.hexString, "\(s.path.count)",
            "\(s.path.creationDate.timeIntervalSince1970)",
            f(first.x), f(first.y), f(last.x), f(last.y),
            f(t.a), f(t.b), f(t.c), f(t.d), f(t.tx), f(t.ty), s.mask == nil ? "" : "m",
        ].joined(separator: "|")
    }

    private static func f(_ v: CGFloat) -> String { String(format: "%.2f", Double(v)) }
    private static func round2(_ v: Double) -> Double { (v * 100).rounded() / 100 }
}

extension UIColor {
    convenience init(hex: String) {
        let s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        let v: UInt64 = s.count == 6 ? (UInt64(s, radix: 16) ?? 0x111111) : 0x111111
        self.init(red: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
                  blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }

    /// #rrggbb, as drawn in light mode (OpenPad pages are always light).
    var hexString: String {
        let c = resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        if !c.getRed(&r, green: &g, blue: &b, alpha: &a) {
            var w: CGFloat = 0
            c.getWhite(&w, alpha: &a)
            r = w; g = w; b = w
        }
        let clamp = { (x: CGFloat) in Int((min(1, max(0, x)) * 255).rounded()) }
        return String(format: "#%02x%02x%02x", clamp(r), clamp(g), clamp(b))
    }
}
