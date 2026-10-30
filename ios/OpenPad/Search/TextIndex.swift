import Foundation
import OpenPadCore
import PDFKit
import UIKit
import Vision

/// Text of every page, for search: handwriting recognized on this iPad
/// (Vision), the text of PDF pages, and titles. Kept for offloaded notebooks
/// too, so search still finds them. Stored in Application Support/OpenPad/text.json.
@MainActor
final class TextIndex {
    struct Entry: Codable {
        var nb: String
        var key: String
        var title: String  // "Section · Page title"
        var text: String
    }

    struct Hit: Identifiable, Hashable {
        let nb: String
        let page: String?
        let title: String
        let snippet: String
        var id: String { "\(nb)/\(page ?? "")" }
    }

    private(set) var pages: [String: Entry] = [:]
    private let url: URL
    private var queue: [(nb: String, page: Page, title: String, pdf: URL?)] = []
    private var working = false
    private var saveWork: DispatchWorkItem?

    init(root: URL) {
        url = root.appendingPathComponent("text.json")
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode([String: Entry].self, from: data) {
            pages = saved
        }
    }

    private static func key(_ p: Page) -> String {
        "\(p.strokes.count).\(p.strokes.last?.id ?? "").\(p.gone.count).\(p.bg?.asset ?? "")\(p.bg?.n ?? 0)"
    }

    /// Re-read pages of a notebook that changed (recognition runs in the background).
    func schedule(_ nb: Notebook, store: Store) {
        for sec in nb.layout.sections {
            for id in sec.pages {
                guard let page = nb.pages[id] else { continue }
                let title = page.title.isEmpty ? sec.title : "\(sec.title) · \(page.title)"
                let key = Self.key(page)
                if var e = pages[id] {
                    if e.title != title { e.title = title; pages[id] = e; saveSoon() }
                    if e.key == key { continue }
                } else if page.strokes.isEmpty && page.bg?.pdf == nil {
                    pages[id] = Entry(nb: nb.id, key: key, title: title, text: "")
                    saveSoon()
                    continue
                }
                queue.removeAll { $0.page.id == id }
                queue.append((nb.id, page, title, page.bg?.pdf.map { store.assetURL($0) }))
            }
        }
        // Pages that no longer exist.
        let live = Set(nb.pages.keys)
        for (id, e) in pages where e.nb == nb.id && !live.contains(id) { pages[id] = nil }
        work()
    }

    func remove(notebook id: String) {
        pages = pages.filter { $0.value.nb != id }
        saveSoon()
    }

    private func work() {
        guard !working, !queue.isEmpty else { return }
        working = true
        let item = queue.removeFirst()
        let image = Self.inkImage(item.page)
        var pdfText = ""
        if let pdf = item.pdf, let n = item.page.bg?.n, let doc = PDFDocument(url: pdf) {
            pdfText = doc.page(at: n - 1)?.string ?? ""
        }
        Task {
            let ink = await Self.recognize(image)
            pages[item.page.id] = Entry(nb: item.nb, key: Self.key(item.page), title: item.title,
                                        text: [ink, pdfText].filter { !$0.isEmpty }.joined(separator: "\n"))
            saveSoon()
            working = false
            work()
        }
    }

    /// The page's ink in black on white, for recognition.
    private static func inkImage(_ page: Page) -> CGImage? {
        guard !page.strokes.isEmpty else { return nil }
        let k: CGFloat = 1.4
        let size = CGSize(width: CGFloat(page.w) * k, height: CGFloat(page.h) * k)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { r in
            let ctx = r.cgContext
            ctx.setFillColor(UIColor.white.cgColor)
            ctx.fill(CGRect(origin: .zero, size: size))
            ctx.scaleBy(x: k, y: k)
            for var s in page.strokes where s.tool == "pen" {
                s.color = "#000000"
                PageRenderer.drawStroke(s, in: ctx)
            }
        }
        return image.cgImage
    }

    private nonisolated static func recognize(_ image: CGImage?) async -> String {
        guard let image else { return "" }
        return await Task.detached(priority: .background) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            do {
                try VNImageRequestHandler(cgImage: image).perform([request])
            } catch {
                return ""
            }
            return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        }.value
    }

    private func saveSoon() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let data = try? JSONEncoder().encode(self.pages) else { return }
            try? data.write(to: self.url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    /// Pages whose title, handwriting or PDF text contains every word of `query`.
    func search(_ query: String, notebooks: [NotebookEntry]) -> [Hit] {
        let words = query.lowercased().split(separator: " ").map(String.init).filter { !$0.isEmpty }
        guard !words.isEmpty else { return [] }
        var hits: [Hit] = []
        for e in notebooks {
            let hay = "\(e.title) \(e.folder)".lowercased()
            if words.allSatisfy({ hay.contains($0) }) {
                hits.append(Hit(nb: e.id, page: nil, title: e.title, snippet: e.folder.isEmpty ? "Notebook" : e.folder))
            }
        }
        let titles = Dictionary(notebooks.map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a })
        for (id, e) in pages {
            guard let nbTitle = titles[e.nb] else { continue }
            let hay = (e.title + "\n" + e.text).lowercased()
            guard words.allSatisfy({ hay.contains($0) }) else { continue }
            hits.append(Hit(nb: e.nb, page: id, title: "\(nbTitle) › \(e.title)", snippet: Self.snippet(e.text, around: words[0])))
        }
        return hits
    }

    private static func snippet(_ text: String, around word: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        guard let r = flat.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) else { return String(flat.prefix(90)) }
        let start = flat.index(r.lowerBound, offsetBy: -40, limitedBy: flat.startIndex) ?? flat.startIndex
        let end = flat.index(r.upperBound, offsetBy: 60, limitedBy: flat.endIndex) ?? flat.endIndex
        return (start > flat.startIndex ? "…" : "") + flat[start..<end] + (end < flat.endIndex ? "…" : "")
    }
}
