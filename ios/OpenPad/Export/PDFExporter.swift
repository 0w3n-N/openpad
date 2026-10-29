import OpenPadCore
import PDFKit
import UIKit

/// Pages as a PDF: paper and ink as vectors, PDF backgrounds embedded as the
/// original vector pages, images as images. Sections become bookmarks.
@MainActor
enum PDFExporter {
    static func render(pages: [Page], title: String, store: Store, liveFrame: UIImage? = nil,
                       outline: [(String, Int)] = []) -> Data {
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [kCGPDFContextTitle as String: title, kCGPDFContextCreator as String: "OpenPad"]
        let first = pages.first.map { CGRect(x: 0, y: 0, width: $0.pt[0], height: $0.pt[1]) } ?? CGRect(x: 0, y: 0, width: 612, height: 792)
        let renderer = UIGraphicsPDFRenderer(bounds: first, format: format)
        let data = renderer.pdfData { ctx in
            for page in pages {
                let w = page.pt.count == 2 ? page.pt[0] : 612
                let h = page.pt.count == 2 ? page.pt[1] : 612 * page.h / page.w
                ctx.beginPage(withBounds: CGRect(x: 0, y: 0, width: w, height: h), pageInfo: [:])
                let cg = ctx.cgContext
                let k = CGFloat(w) / CGFloat(page.w)
                cg.saveGState()
                cg.scaleBy(x: k, y: CGFloat(h) / CGFloat(page.h))
                PageRenderer.drawPaper(page, in: cg, scale: k)
                PageRenderer.drawBackground(page, in: cg, store: store, liveFrame: liveFrame)
                for s in page.strokes { PageRenderer.drawStroke(s, in: cg) }
                cg.restoreGState()
            }
        }
        guard !outline.isEmpty, let doc = PDFDocument(data: data) else { return data }
        let root = PDFOutline()
        for (i, (name, index)) in outline.enumerated() {
            guard let page = doc.page(at: index) else { continue }
            let item = PDFOutline()
            item.label = name
            item.destination = PDFDestination(page: page, at: CGPoint(x: 0, y: page.bounds(for: .mediaBox).height))
            root.insertChild(item, at: i)
        }
        doc.outlineRoot = root
        return doc.dataRepresentation() ?? data
    }
}
