import CoreGraphics
import OpenPadCore
import UIKit

/// Draws pages with CoreGraphics, the same way web/ink.js does: paper,
/// backgrounds (PDF pages stay vector) and ink. Used for thumbnails and PDFs.
enum PageRenderer {
    /// Paper lines as (from, to, color, width) in page units.
    static func paperLines(_ page: Page) -> [(CGPoint, CGPoint, UIColor, CGFloat)] {
        guard page.bg == nil else { return [] }
        let w = CGFloat(page.w), h = CGFloat(page.h)
        var out: [(CGPoint, CGPoint, UIColor, CGFloat)] = []
        switch page.paper {
        case "lines":
            var y: CGFloat = 64
            while y < h - 8 {
                out.append((CGPoint(x: 0, y: y), CGPoint(x: w, y: y), UIColor(hex: "#c8d6ea"), 1))
                y += 32
            }
            out.append((CGPoint(x: 80, y: 0), CGPoint(x: 80, y: h), UIColor(hex: "#f0b4b4"), 1))
        case "grid":
            var y: CGFloat = 32
            while y < h { out.append((CGPoint(x: 0, y: y), CGPoint(x: w, y: y), UIColor(hex: "#dbe2ec"), 1)); y += 32 }
            var x: CGFloat = 32
            while x < w { out.append((CGPoint(x: x, y: 0), CGPoint(x: x, y: h), UIColor(hex: "#dbe2ec"), 1)); x += 32 }
        case "eng":
            var i = 1
            var y: CGFloat = 10
            while y < h {
                out.append((CGPoint(x: 0, y: y), CGPoint(x: w, y: y), UIColor(hex: i % 5 == 0 ? "#b7c7da" : "#e3eaf2"), i % 5 == 0 ? 1 : 0.6))
                y += 10
                i += 1
            }
            i = 1
            var x: CGFloat = 10
            while x < w {
                out.append((CGPoint(x: x, y: 0), CGPoint(x: x, y: h), UIColor(hex: i % 5 == 0 ? "#b7c7da" : "#e3eaf2"), i % 5 == 0 ? 1 : 0.6))
                x += 10
                i += 1
            }
        default:
            break
        }
        return out
    }

    /// Paper in page units (the context is already scaled).
    static func drawPaper(_ page: Page, in ctx: CGContext, scale k: CGFloat) {
        ctx.setFillColor(page.bg?.live == true ? UIColor.black.cgColor : UIColor.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: page.w, height: page.h))
        guard page.bg == nil else { return }
        if page.paper == "dots" {
            ctx.setFillColor(UIColor(hex: "#b9c0cc").cgColor)
            let r = max(1 / k, 1.6)
            var y: CGFloat = 32
            while y < CGFloat(page.h) {
                var x: CGFloat = 32
                while x < CGFloat(page.w) {
                    ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
                    x += 32
                }
                y += 32
            }
            return
        }
        for (a, b, color, width) in paperLines(page) {
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(max(0.6 / k, width))
            ctx.move(to: a)
            ctx.addLine(to: b)
            ctx.strokePath()
        }
    }

    /// A PDF page or image background, filling the page (page units).
    @MainActor
    static func drawBackground(_ page: Page, in ctx: CGContext, store: Store, liveFrame: UIImage? = nil) {
        let rect = CGRect(x: 0, y: 0, width: page.w, height: page.h)
        if let sha = page.bg?.pdf, let n = page.bg?.n, let pdfPage = PDFAssets.shared.page(sha, n, store: store) {
            drawPDFPage(pdfPage, in: ctx, rect: rect)
        } else if let sha = page.bg?.img, let image = PDFAssets.shared.image(sha, store: store) {
            image.draw(in: rect)
        } else if page.bg?.live == true, let liveFrame {
            liveFrame.draw(in: rect)
        }
    }

    /// Draw a PDF page into a rect of a UIKit-oriented (y down) context.
    static func drawPDFPage(_ pdfPage: CGPDFPage, in ctx: CGContext, rect: CGRect) {
        ctx.saveGState()
        ctx.setFillColor(UIColor.white.cgColor)
        ctx.fill(rect)
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        let box = pdfPage.getBoxRect(.cropBox)
        let rotated = pdfPage.rotationAngle % 180 != 0
        let size = rotated ? CGSize(width: box.height, height: box.width) : box.size
        // Stretch exactly onto the page (its shape came from this PDF page).
        let target = CGRect(origin: .zero, size: rect.size)
        ctx.scaleBy(x: target.width / max(1, size.width), y: target.height / max(1, size.height))
        ctx.concatenate(pdfPage.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: size), rotate: 0,
                                                    preserveAspectRatio: true))
        ctx.drawPDFPage(pdfPage)
        ctx.restoreGState()
    }

    /// Ink, exactly as web/ink.js draws it: quadratic segments through the
    /// midpoints, with the width following pressure.
    /// `clip` (page units) skips the pieces of a long stroke outside it.
    static func drawStroke(_ s: Stroke, in ctx: CGContext, clip: CGRect? = nil) {
        let p = s.pts.filter { $0.count >= 2 }
        guard let first = p.first else { return }
        let color = UIColor(hex: s.color).cgColor
        ctx.saveGState()
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setStrokeColor(color)
        ctx.setFillColor(color)
        func pr(_ q: [Double]) -> CGFloat { CGFloat(q.count > 2 ? min(1, max(0, q[2])) : 0.5) }
        func width(_ q: [Double]) -> CGFloat { CGFloat(s.width) * (0.35 + 1.15 * pr(q)) }
        if s.tool == "hl" {
            ctx.setAlpha(0.32)
            ctx.setBlendMode(.multiply)
            ctx.setLineWidth(CGFloat(s.width))
            ctx.move(to: CGPoint(x: first[0], y: first[1]))
            if p.count == 1 { ctx.addLine(to: CGPoint(x: first[0] + 0.01, y: first[1])) }
            forEachSegment(p) { _, c, end, isLine, _ in
                if isLine { ctx.addLine(to: end) } else { ctx.addQuadCurve(to: end, control: c) }
            }
            ctx.strokePath()
        } else if p.count == 1 {
            let r = max(0.1, width(first) / 2)
            ctx.fillEllipse(in: CGRect(x: first[0] - Double(r), y: first[1] - Double(r), width: Double(r * 2), height: Double(r * 2)))
        } else {
            let margin = CGFloat(s.width) * 1.5
            forEachSegment(p) { start, c, end, isLine, i in
                if let clip {
                    let x0 = min(start.x, c.x, end.x), y0 = min(start.y, c.y, end.y)
                    let box = CGRect(x: x0, y: y0, width: max(start.x, c.x, end.x) - x0, height: max(start.y, c.y, end.y) - y0)
                        .insetBy(dx: -margin, dy: -margin)
                    if !box.intersects(clip) { return }
                }
                ctx.setLineWidth(width(p[i]))
                ctx.move(to: start)
                if isLine { ctx.addLine(to: end) } else { ctx.addQuadCurve(to: end, control: c) }
                ctx.strokePath()
            }
        }
        ctx.restoreGState()
    }

    /// Calls body(start, control, end, isLastStraightSegment, pointIndex) like web/ink.js segments().
    private static func forEachSegment(_ p: [[Double]], _ body: (CGPoint, CGPoint, CGPoint, Bool, Int) -> Void) {
        var x0 = p[0][0], y0 = p[0][1]
        for i in 1..<p.count {
            let last = i == p.count - 1
            let x1 = last ? p[i][0] : (p[i][0] + p[i + 1][0]) / 2
            let y1 = last ? p[i][1] : (p[i][1] + p[i + 1][1]) / 2
            body(CGPoint(x: x0, y: y0), CGPoint(x: p[i][0], y: p[i][1]), CGPoint(x: x1, y: y1), last, i)
            x0 = x1
            y0 = y1
        }
    }

    /// A small picture of a page for the sidebar.
    @MainActor
    static func thumbnail(_ page: Page, width: CGFloat, store: Store) -> UIImage {
        let k = width / CGFloat(page.w)
        let size = CGSize(width: width, height: CGFloat(page.h) * k)
        return UIGraphicsImageRenderer(size: size).image { r in
            let ctx = r.cgContext
            ctx.scaleBy(x: k, y: k)
            drawPaper(page, in: ctx, scale: k)
            drawBackground(page, in: ctx, store: store)
            for s in page.strokes { drawStroke(s, in: ctx) }
        }
    }
}

/// Opened PDFs and images, by the SHA-256 they're stored under.
final class PDFAssets: @unchecked Sendable {
    static let shared = PDFAssets()
    private var docs: [String: CGPDFDocument] = [:]
    private var images = NSCache<NSString, UIImage>()
    private let lock = NSLock()

    @MainActor
    func page(_ sha: String, _ n: Int, store: Store) -> CGPDFPage? {
        document(sha, url: store.assetURL(sha))?.page(at: n)
    }

    /// Thread-safe (CATiledLayer draws on background threads).
    func document(_ sha: String, url: URL) -> CGPDFDocument? {
        lock.lock()
        defer { lock.unlock() }
        if let d = docs[sha] { return d }
        guard let d = CGPDFDocument(url as CFURL) else { return nil }
        docs[sha] = d
        return d
    }

    @MainActor
    func image(_ sha: String, store: Store) -> UIImage? {
        if let i = images.object(forKey: sha as NSString) { return i }
        guard let i = UIImage(contentsOfFile: store.assetURL(sha).path) else { return nil }
        images.setObject(i, forKey: sha as NSString)
        return i
    }

    /// PDF page sizes in points (rotation applied), for importing.
    static func pageSizes(_ data: Data) -> [[Double]]? {
        guard let provider = CGDataProvider(data: data as CFData), let doc = CGPDFDocument(provider), doc.numberOfPages > 0 else { return nil }
        return (1...min(doc.numberOfPages, 2000)).compactMap { i in
            guard let p = doc.page(at: i) else { return nil }
            let box = p.getBoxRect(.cropBox)
            let rotated = p.rotationAngle % 180 != 0
            let w = rotated ? box.height : box.width, h = rotated ? box.width : box.height
            return [(Double(w) * 100).rounded() / 100, (Double(h) * 100).rounded() / 100]
        }
    }
}

extension UIColor {
    /// A stroke's #rrggbb color.
    convenience init(hex: String) {
        let s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        let v: UInt64 = s.count == 6 ? (UInt64(s, radix: 16) ?? 0x111111) : 0x111111
        self.init(red: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
                  blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }
}
