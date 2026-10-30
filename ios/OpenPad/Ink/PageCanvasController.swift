import OpenPadCore
import UIKit

/// Paper and PDF pages, drawn in tiles so they stay sharp at any zoom. Its
/// bounds are the page in page units and the zoom scales it: tiles drawn at
/// one size never get stretched to another.
final class TiledPageView: UIView {
    struct Content: Equatable {
        var page: Page
        var pdfURL: URL?
        var displayScale: CGFloat
    }

    override class var layerClass: AnyClass { CATiledLayer.self }

    private let lock = NSLock()
    private var _content: Content?
    var content: Content? {
        get { lock.lock(); defer { lock.unlock() }; return _content }
        set {
            lock.lock()
            let changed = _content != newValue
            _content = newValue
            lock.unlock()
            if changed { setNeedsDisplay() }
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        let tiled = layer as! CATiledLayer
        tiled.levelsOfDetail = 4
        tiled.levelsOfDetailBias = 4
        tiled.tileSize = CGSize(width: 512, height: 512)
        // Tiles not drawn yet stay see-through (the white page behind them
        // shows), never black.
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // Called on background threads, one tile at a time.
    override func draw(_ rect: CGRect) {
        guard let content, let ctx = UIGraphicsGetCurrentContext() else { return }
        let page = content.page
        // Screen points per page unit at this tile's level of detail.
        let k = max(0.01, abs(ctx.ctm.a) / max(1, content.displayScale))
        PageRenderer.drawPaper(page, in: ctx, scale: k)
        if let url = content.pdfURL, let sha = page.bg?.pdf, let n = page.bg?.n,
           let pdfPage = PDFAssets.shared.document(sha, url: url)?.page(at: n) {
            PageRenderer.drawPDFPage(pdfPage, in: ctx, rect: CGRect(x: 0, y: 0, width: page.w, height: page.h))
        }
    }
}

/// One page and OpenPad's own ink: the same tools, strokes and rendering as
/// the web app (web/editor.js), so ink looks the same on the iPad, on the
/// computer and in PDFs.
///
/// The page view is in page units (1000 wide) inside a zooming scroll view;
/// paper and finished ink are tiled layers inside it. What's being drawn right
/// now is on a screen-sized layer above (LiveInkView), redrawn only where it
/// changes. Fingers scroll and zoom; the Pencil draws (a finger too, if
/// that's switched on, with two fingers to scroll).
@MainActor
final class PageCanvasController: UIViewController, UIScrollViewDelegate, UIGestureRecognizerDelegate, UIPencilInteractionDelegate {
    let scroll = UIScrollView()
    private let pageView = UIView()
    private let paper = TiledPageView()
    private let imageView = UIImageView()
    private let ink = InkTiledView()
    private let live = LiveInkView()
    private let gesture = InkGesture(target: nil, action: nil)
    private let selectionBar = UIStackView()
    weak var model: AppModel?

    private(set) var pageID: String?
    private var notebookID: String?
    private var pageSize = CGSize(width: 1000, height: 1294)
    private var fitScale: CGFloat = 1
    private(set) var drawingActive = false
    private var fitted = true
    private var lastSize: CGSize = .zero
    private var lastCursor: TimeInterval = 0

    // MARK: what's being drawn

    private enum Kind { case ink, erase, lasso, move, shape }

    private struct Drawing {
        var kind: Kind
        var page: String
        var t0: TimeInterval
        var origin: CGPoint  // where it started, on screen
        var moved: CGFloat = 0  // furthest from the origin, on screen
        var start: [Double]
        var stroke: Stroke?
        var predicted: [[Double]] = []
        var removed: [Stroke] = []
        var straight: Stroke?
        var still: (t: TimeInterval, at: CGPoint)
        var from: [Double]?
        var unsent: [[Double]] = []
        var lastSend: TimeInterval = 0
        var liveBox: CGRect = .null  // the predicted tail last drawn
    }

    private var drawing: Drawing?
    private var holdTimer: Timer?
    private var eraserAt: (x: Double, y: Double, r: Double)?
    private var lasso: [[Double]]?
    private struct Selection {
        var page: String
        var ids: [String]
        var drag: (Double, Double)?
    }

    private var selection: Selection?
    private var finishing: [String: Stroke] = [:]  // finished strokes shown here until their tiles are drawn
    private var remoteActive: Set<String> = []  // others' strokes still being written

    private struct UndoOp {
        var page: String
        var removed: [Stroke]
        var added: [Stroke]
    }

    private var undoStack: [UndoOp] = []
    private var redoStack: [UndoOp] = []

    // Hold the pen still at the end of a stroke to make it a straight line.
    private let holdSeconds = 0.55
    private let holdPixels: CGFloat = 4
    private let eraserRadius = 10.0

    init(model: AppModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(white: 0.12, alpha: 1)
        scroll.frame = view.bounds
        scroll.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scroll.delegate = self
        scroll.backgroundColor = .clear
        scroll.alwaysBounceVertical = true
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.delaysContentTouches = false
        scroll.panGestureRecognizer.allowedTouchTypes = [
            NSNumber(value: UITouch.TouchType.direct.rawValue),
            NSNumber(value: UITouch.TouchType.indirect.rawValue),
            NSNumber(value: UITouch.TouchType.indirectPointer.rawValue),
        ]
        view.addSubview(scroll)

        pageView.backgroundColor = .white
        pageView.layer.shadowColor = UIColor.black.cgColor
        pageView.layer.shadowOpacity = 0.35
        pageView.layer.shadowRadius = 12
        imageView.contentMode = .scaleToFill
        for v in [paper, imageView, ink] as [UIView] { pageView.addSubview(v) }
        scroll.addSubview(pageView)

        live.frame = view.bounds
        live.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        live.pageView = pageView
        live.drawContent = { [weak self] ctx, clip in self?.drawLive(ctx, clip: clip) }
        view.addSubview(live)

        gesture.delegate = self
        gesture.onBegan = { [weak self] t, e in self?.touchBegan(t, e) }
        gesture.onMoved = { [weak self] t, e in self?.touchMoved(t, e) }
        gesture.onEnded = { [weak self] t, _, cancelled in self?.touchEnded(t, cancelled: cancelled) }
        scroll.addGestureRecognizer(gesture)
        scroll.addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:))))
        let pencil = UIPencilInteraction()
        pencil.delegate = self
        view.addInteraction(pencil)

        buildSelectionBar()
        setPageSize(pageSize)
        applySettings()
        if let model, let id = model.pageID { show(pageID: id, refit: true, from: model) }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if view.bounds.size != lastSize {
            lastSize = view.bounds.size
            if fitted { fit() } else { updateLayout() }
        }
    }

    func applySettings() {
        let fingers = model?.fingerDrawing ?? false
        gesture.fingers = fingers
        // The Pencil never scrolls or zooms (the pinch exists once zooming is set up).
        scroll.pinchGestureRecognizer?.allowedTouchTypes = [
            NSNumber(value: UITouch.TouchType.direct.rawValue),
            NSNumber(value: UITouch.TouchType.indirectPointer.rawValue),
        ]
        // With a finger drawing, scrolling takes two.
        scroll.panGestureRecognizer.minimumNumberOfTouches = fingers ? 2 : 1
    }

    // MARK: pages

    /// Show a page of the open notebook (or refresh the current one).
    func show(pageID: String, refit: Bool, from model: AppModel) {
        guard let nb = model.notebook, let page = nb.pages[pageID] else { return }
        if nb.id != notebookID {
            notebookID = nb.id
            undoStack = []
            redoStack = []
            publishUndo()
        }
        let changed = pageID != self.pageID
        self.pageID = pageID
        if changed {
            cancelDrawing()
            clearSelection()
            remoteActive = []
            finishing = [:]
            ink.reset()
        }
        let size = CGSize(width: page.w, height: page.h)
        if size != pageSize { setPageSize(size) }
        configureBackground(page)
        refreshInk()
        if refit || changed { fit() } else { updateLayout() }
    }

    private func setPageSize(_ size: CGSize) {
        pageSize = size
        scroll.minimumZoomScale = 0.01
        scroll.maximumZoomScale = 100
        scroll.zoomScale = 1
        pageView.frame = CGRect(origin: .zero, size: size)
        for v in [paper, imageView, ink] as [UIView] { v.frame = pageView.bounds }
        pageView.layer.shadowPath = UIBezierPath(rect: pageView.bounds).cgPath  // no offscreen pass while zooming
        scroll.contentSize = size
        ink.reset()
    }

    private func configureBackground(_ page: Page) {
        guard let model else { return }
        let pdfURL = page.bg?.pdf.map { model.store.assetURL($0) }
        paper.content = TiledPageView.Content(page: page.metaOnly, pdfURL: pdfURL, displayScale: view.traitCollection.displayScale)
        if let sha = page.bg?.img {
            imageView.image = PDFAssets.shared.image(sha, store: model.store)
        } else if page.bg?.live == true {
            imageView.image = model.liveFrame
        } else {
            imageView.image = nil
        }
        imageView.isHidden = imageView.image == nil
        pageView.backgroundColor = page.bg?.live == true ? .black : .white
    }

    /// A new frame of the live desktop window.
    func liveFrameChanged(_ image: UIImage?) {
        guard let model, let id = pageID, model.notebook?.pages[id]?.bg?.live == true else { return }
        imageView.image = image
        imageView.isHidden = image == nil
    }

    /// The model changed this page (sync, guests, page settings, local edits).
    func reloadFromModel() {
        guard let model, let id = pageID, let page = model.notebook?.pages[id] else { return }
        let size = CGSize(width: page.w, height: page.h)
        if size != pageSize {
            setPageSize(size)
            fit()
        }
        configureBackground(page)
        if var sel = selection {
            let present = Set(page.strokes.map(\.id))
            sel.ids = sel.ids.filter { present.contains($0) }
            selection = sel.ids.isEmpty ? nil : sel
            updateSelection()
        }
        refreshInk()
    }

    private var pageStrokes: [Stroke] {
        guard let id = pageID else { return [] }
        return model?.notebook?.pages[id]?.strokes ?? []
    }

    private func refreshInk() {
        var hidden = remoteActive
        if let sel = selection, sel.drag != nil { hidden.formUnion(sel.ids) }
        ink.show(pageStrokes, hidden: hidden)
    }

    // MARK: zoom

    private func fit() {
        guard view.bounds.width > 0 else { return }
        let margin: CGFloat = 16
        let byWidth = (view.bounds.width - margin * 2) / pageSize.width
        let byHeight = (view.bounds.height - margin * 2) / pageSize.height
        // Portrait pages fit the width (scroll down); wide ones fit whole.
        let s = pageSize.height / pageSize.width > 1.05 && view.bounds.height / view.bounds.width < pageSize.height / pageSize.width
            ? byWidth : min(byWidth, byHeight)
        fitScale = s
        scroll.minimumZoomScale = max(0.05, min(byWidth, byHeight) * 0.6)
        scroll.maximumZoomScale = max(s * 8, 4)
        scroll.zoomScale = s
        fitted = true
        updateLayout()
        scroll.contentOffset = CGPoint(x: -scroll.contentInset.left, y: -scroll.contentInset.top)
    }

    private func updateLayout() {
        let size = pageView.frame.size
        let insetX = max(16, (scroll.bounds.width - size.width) / 2)
        // Portrait pages start at the top, like paper; wide pages are centered.
        let spare = max(0, scroll.bounds.height - size.height)
        let top = pageSize.height > pageSize.width ? min(16, spare) : max(16, spare / 2)
        let bottom = max(16, spare - top)
        scroll.contentInset = UIEdgeInsets(top: top, left: insetX, bottom: bottom, right: insetX)
        live.setNeedsDisplay()
        updateSelection()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { pageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        fitted = false
        updateLayout()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        live.setNeedsDisplay()
        positionSelectionBar()
    }

    func resetZoom() { fit() }

    // MARK: input

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }

    /// One input point: where it is on the page and on screen, and the
    /// Pencil's raw pressure (nil for a finger).
    struct Sample {
        var x: Double
        var y: Double
        var raw: Double?
        var screen: CGPoint
    }

    private func sample(_ t: UITouch) -> Sample {
        let p = t.type == .pencil ? t.preciseLocation(in: pageView) : t.location(in: pageView)
        let raw = t.type == .pencil ? max(0.05, Double(t.force / max(t.maximumPossibleForce, 0.0001))) : nil
        return Sample(x: Double(p.x), y: Double(p.y), raw: raw, screen: t.location(in: view))
    }

    private func touchBegan(_ t: UITouch, _ e: UIEvent) {
        began(sample(t), pencil: t.type == .pencil)
    }

    private func touchMoved(_ t: UITouch, _ e: UIEvent) {
        moved((e.coalescedTouches(for: t) ?? [t]).map(sample), predicted: (e.predictedTouches(for: t) ?? []).map(sample),
              pencil: t.type == .pencil)
    }

    private func touchEnded(_ t: UITouch, cancelled: Bool) {
        ended(pencil: t.type == .pencil, cancelled: cancelled)
    }

    /// A sample as a stored point: [x, y, pressure] in page units.
    private func point(_ s: Sample, previous: Double?) -> [Double] {
        let pressure = s.raw.map { Ink.shapePressure($0, sensitivity: model?.pressure ?? 0.35, previous: previous) } ?? Ink.neutralPressure
        return [Ink.round2(s.x), Ink.round2(s.y), Ink.round3(pressure)]
    }

    private func began(_ input: Sample, pencil: Bool) {
        guard let model, let pid = pageID, model.notebook?.pages[pid] != nil else { return }
        let pt = point(input, previous: nil)
        let now = CACurrentMediaTime()
        var d = Drawing(kind: .ink, page: pid, t0: now, origin: input.screen, start: pt, still: (now, input.screen))
        drawingActive = true
        switch model.tool {
        case .lasso:
            if selection != nil, inBox(pt) {
                d.kind = .move
                d.from = pt
                selection?.drag = (0, 0)
                selectionBar.isHidden = true
                refreshInk()
            } else {
                clearSelection()
                d.kind = .lasso
                lasso = [pt]
            }
            drawing = d
        case .eraser:
            d.kind = .erase
            drawing = d
            eraseAt(pt)
        case .shape:
            d.kind = .shape
            d.stroke = Stroke(id: newID(), z: nextZ(), tool: "pen", color: model.color, width: model.width, pts: [pt])
            drawing = d
        case .pen, .highlighter:
            let hl = model.tool == .highlighter
            let s = Stroke(id: newID(), z: nextZ(), tool: hl ? "hl" : "pen",
                           color: hl && model.color == Ink.colors[0] ? Ink.highlighterYellow : model.color,
                           width: hl ? Ink.highlighterWidth(model.width) : model.width, pts: [pt])
            d.stroke = s
            d.lastSend = now
            drawing = d
            model.strokeStarted(page: pid, stroke: s)
            armHold()
            live.invalidate(page: InkTiledView.box(s))
        }
        if pencil { cursor(at: CGPoint(x: pt[0], y: pt[1])) }
    }

    private func moved(_ samples: [Sample], predicted: [Sample], pencil: Bool) {
        guard var d = drawing, let latest = samples.last else { return }
        for c in samples { d.moved = max(d.moved, hypot(c.screen.x - d.origin.x, c.screen.y - d.origin.y)) }
        if pencil { cursor(at: CGPoint(x: latest.x, y: latest.y)) }
        switch d.kind {
        case .erase:
            drawing = d
            for c in samples { eraseAt(point(c, previous: nil)) }
        case .lasso:
            drawing = d
            lasso? += samples.map { point($0, previous: nil) }
            live.setNeedsDisplay()
        case .move:
            drawing = d
            let p = point(latest, previous: nil)
            if let from = d.from { selection?.drag = (p[0] - from[0], p[1] - from[1]) }
            live.setNeedsDisplay()
        case .shape:
            guard var s = d.stroke, let model else { return }
            let before = InkTiledView.box(s)
            s.pts = Ink.shapePoints(model.shape, from: d.start, to: point(latest, previous: nil))
            d.stroke = s
            drawing = d
            live.invalidate(page: before.union(InkTiledView.box(s)))
        case .ink:
            inkMoved(&d, samples, predicted: predicted)
            drawing = d
        }
    }

    private func inkMoved(_ d: inout Drawing, _ samples: [Sample], predicted: [Sample]) {
        guard var s = d.stroke, let latest = samples.last else { return }
        if var line = d.straight {
            let before = InkTiledView.box(line)
            line.pts = Ink.line(line.pts[0], point(latest, previous: nil))
            d.straight = line
            live.invalidate(page: before.union(InkTiledView.box(line)))
            return
        }
        let before = s.pts.count
        for c in samples {
            let pt = point(c, previous: s.pts.last?[2])
            guard let last = s.pts.last, abs(pt[0] - last[0]) + abs(pt[1] - last[1]) >= 0.35 else { continue }
            s.pts.append(pt)
            d.unsent.append(pt)
        }
        let lastPressure = s.pts.last?[2] ?? Ink.neutralPressure
        d.predicted = predicted.map { [$0.x, $0.y, lastPressure] }
        d.stroke = s
        // Redraw the new part (from two points back: the last curve changes
        // shape), and where the predicted tail was and is now.
        let fresh = Array(s.pts[max(0, before - 2)...]) + d.predicted
        let dirty = d.liveBox.union(Self.box(of: fresh, width: s.width))
        d.liveBox = Self.box(of: Array(s.pts.suffix(1)) + d.predicted, width: s.width)
        live.invalidate(page: dirty)
        // Held still: snap to a straight line (see armHold).
        if hypot(latest.screen.x - d.still.at.x, latest.screen.y - d.still.at.y) > holdPixels {
            d.still = (CACurrentMediaTime(), latest.screen)
            drawing = d
            armHold()
        }
        // Send the new points to the computer about 30 times a second.
        let now = CACurrentMediaTime()
        if now - d.lastSend > 1.0 / 30, !d.unsent.isEmpty {
            model?.strokePoints(id: s.id, points: d.unsent)
            d.unsent = []
            d.lastSend = now
        }
    }

    private static func box(of pts: [[Double]], width: Double) -> CGRect {
        var r = CGRect.null
        for p in pts where p.count >= 2 { r = r.union(CGRect(x: p[0], y: p[1], width: 0, height: 0)) }
        return r.isNull ? r : r.insetBy(dx: -width * 1.5 - 2, dy: -width * 1.5 - 2)
    }

    private func armHold() {
        holdTimer?.invalidate()
        guard let d = drawing, d.kind == .ink, d.stroke?.tool == "pen", d.straight == nil else { return }
        holdTimer = Timer.scheduledTimer(withTimeInterval: holdSeconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.straighten() }
        }
    }

    private func straighten() {
        guard var d = drawing, d.kind == .ink, d.moved >= 24, d.straight == nil, let s = d.stroke,
              let a = s.pts.first, let b = s.pts.last else { return }
        let line = Stroke(id: newID(), z: s.z, tool: "pen", color: s.color, width: s.width, pts: Ink.line(a, b))
        d.straight = line
        d.predicted = []
        drawing = d
        live.invalidate(page: InkTiledView.box(s).union(InkTiledView.box(line)))
    }

    private func ended(pencil: Bool, cancelled: Bool) {
        holdTimer?.invalidate()
        holdTimer = nil
        guard let d = drawing, let model else {
            drawingActive = false
            return
        }
        drawing = nil
        drawingActive = false
        if pencil { model.sendCursor(nil) }
        switch d.kind {
        case .ink:
            guard let s = d.stroke else { break }
            if !d.unsent.isEmpty { model.strokePoints(id: s.id, points: d.unsent) }
            live.invalidate(page: InkTiledView.box(s).union(d.liveBox))
            if cancelled {
                model.strokeCancelled(page: d.page, id: s.id)
            } else if let line = d.straight {
                // Swap the freehand stroke for the straight line.
                model.strokeCancelled(page: d.page, id: s.id)
                commit(d.page, added: [line], removed: [])
                push(UndoOp(page: d.page, removed: [], added: [line]))
            } else {
                keepOnScreen(s)
                model.strokeFinished(page: d.page, stroke: s)
                push(UndoOp(page: d.page, removed: [], added: [s]))
            }
        case .shape:
            guard let s = d.stroke else { break }
            live.invalidate(page: InkTiledView.box(s))
            if !cancelled, d.moved > 3 {
                commit(d.page, added: [s], removed: [])
                push(UndoOp(page: d.page, removed: [], added: [s]))
            }
        case .erase:
            if let e = eraserAt { live.invalidate(page: CGRect(x: e.x - e.r, y: e.y - e.r, width: e.r * 2, height: e.r * 2)) }
            eraserAt = nil
            if !d.removed.isEmpty { push(UndoOp(page: d.page, removed: d.removed, added: [])) }
        case .lasso:
            finishLasso()
        case .move:
            finishMove()
        }
        refreshInk()
    }

    /// Stop whatever's being drawn (another page was shown).
    private func cancelDrawing() {
        holdTimer?.invalidate()
        holdTimer = nil
        if let d = drawing, d.kind == .ink, let s = d.stroke { model?.strokeCancelled(page: d.page, id: s.id) }
        drawing = nil
        drawingActive = false
        eraserAt = nil
        lasso = nil
        live.setNeedsDisplay()
    }

    /// Keep a finished stroke on the live layer until its tiles are drawn,
    /// so it never blinks.
    private func keepOnScreen(_ s: Stroke) {
        finishing[s.id] = s
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, self.finishing.removeValue(forKey: s.id) != nil else { return }
            self.live.invalidate(page: InkTiledView.box(s))
        }
    }

    /// Add and remove strokes on this iPad (the model saves and sends them).
    private func commit(_ page: String, added: [Stroke], removed: [String]) {
        for s in added { keepOnScreen(s) }
        model?.localStrokes(page: page, added: added, removed: removed)
    }

    // MARK: eraser

    private func eraseAt(_ pt: [Double]) {
        guard var d = drawing, let page = model?.notebook?.pages[d.page] else { return }
        let r = eraserRadius / Double(max(0.5, scroll.zoomScale / max(fitScale, 0.01)))
        let prev = eraserAt.map { [$0.x, $0.y] } ?? pt
        let steps = max(1, Int((hypot(pt[0] - prev[0], pt[1] - prev[1]) / (r / 2)).rounded(.up)))
        if let e = eraserAt { live.invalidate(page: CGRect(x: e.x - e.r, y: e.y - e.r, width: e.r * 2, height: e.r * 2)) }
        eraserAt = (pt[0], pt[1], r)
        live.invalidate(page: CGRect(x: pt[0] - r, y: pt[1] - r, width: r * 2, height: r * 2))
        let hits = page.strokes.filter { s in
            (1...steps).contains { i in
                let f = Double(i) / Double(steps)
                return Ink.hit(s, x: prev[0] + (pt[0] - prev[0]) * f, y: prev[1] + (pt[1] - prev[1]) * f, r: r)
            }
        }
        guard !hits.isEmpty else { return }
        d.removed += hits
        drawing = d
        commit(d.page, added: [], removed: hits.map(\.id))
    }

    // MARK: lasso

    private func finishLasso() {
        let poly = lasso
        lasso = nil
        live.setNeedsDisplay()
        guard let poly, poly.count >= 3, let pid = pageID else { return }
        let ids = pageStrokes.filter { Ink.lassoed($0, polygon: poly) }.map(\.id)
        guard !ids.isEmpty else { return }
        selection = Selection(page: pid, ids: ids, drag: nil)
        updateSelection()
    }

    private var selected: [Stroke] {
        guard let sel = selection else { return [] }
        let byID = Dictionary(pageStrokes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return sel.ids.compactMap { byID[$0] }
    }

    private var selectionBox: CGRect? {
        let ss = selected
        guard !ss.isEmpty, let sel = selection else { return nil }
        let b = ss.map(InkTiledView.box).reduce(CGRect.null) { $0.union($1) }
        let (dx, dy) = sel.drag ?? (0, 0)
        return b.offsetBy(dx: dx, dy: dy).insetBy(dx: -6, dy: -6)
    }

    private func inBox(_ p: [Double]) -> Bool {
        selectionBox?.contains(CGPoint(x: p[0], y: p[1])) ?? false
    }

    private func replaceSelection(_ transform: (Stroke) -> Stroke) {
        guard let sel = selection else { return }
        let old = selected
        guard !old.isEmpty else { return }
        let fresh = Ink.reid(old).map(transform)
        commit(sel.page, added: fresh, removed: old.map(\.id))
        push(UndoOp(page: sel.page, removed: old, added: fresh))
        selection?.ids = fresh.map(\.id)
    }

    private func finishMove() {
        let (dx, dy) = selection?.drag ?? (0, 0)
        selection?.drag = nil
        if abs(dx) + abs(dy) > 0.5 {
            replaceSelection { s in
                var c = s
                c.pts = s.pts.map { p in p.count >= 3 ? [Ink.round2(p[0] + dx), Ink.round2(p[1] + dy), p[2]] : p }
                return c
            }
        }
        refreshInk()
        updateSelection()
    }

    var hasSelection: Bool { selection != nil }

    func deleteSelection() {
        guard let sel = selection else { return }
        let old = selected
        commit(sel.page, added: [], removed: old.map(\.id))
        push(UndoOp(page: sel.page, removed: old, added: []))
        clearSelection()
    }

    func duplicateSelection() {
        guard let sel = selection else { return }
        let copies = Ink.reid(selected).map { s -> Stroke in
            var c = s
            c.z = nextZ()
            c.pts = s.pts.map { p in p.count >= 3 ? [p[0] + 24, p[1] + 24, p[2]] : p }
            return c
        }
        commit(sel.page, added: copies, removed: [])
        push(UndoOp(page: sel.page, removed: [], added: copies))
        selection?.ids = copies.map(\.id)
        updateSelection()
    }

    func recolorSelection(_ color: String) {
        replaceSelection { s in
            var c = s
            c.color = color
            return c
        }
        updateSelection()
    }

    func clearSelection() {
        guard selection != nil || lasso != nil else { return }
        selection = nil
        lasso = nil
        refreshInk()
        live.setNeedsDisplay()
        updateSelection()
    }

    private func buildSelectionBar() {
        selectionBar.axis = .horizontal
        selectionBar.spacing = 4
        selectionBar.isLayoutMarginsRelativeArrangement = true
        selectionBar.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4)
        selectionBar.backgroundColor = .secondarySystemBackground
        selectionBar.layer.cornerRadius = 10
        selectionBar.layer.shadowColor = UIColor.black.cgColor
        selectionBar.layer.shadowOpacity = 0.25
        selectionBar.layer.shadowRadius = 6
        let actions: [(String, () -> Void)] = [
            ("Delete", { [weak self] in self?.deleteSelection() }),
            ("Duplicate", { [weak self] in self?.duplicateSelection() }),
            ("Color", { [weak self] in
                guard let self, let color = self.model?.color else { return }
                self.recolorSelection(color)
            }),
        ]
        for (title, action) in actions {
            var config = UIButton.Configuration.plain()
            config.title = title
            config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10)
            selectionBar.addArrangedSubview(UIButton(configuration: config, primaryAction: UIAction { _ in action() }))
        }
        selectionBar.isHidden = true
        selectionBar.translatesAutoresizingMaskIntoConstraints = true
        view.addSubview(selectionBar)
    }

    private func updateSelection() {
        live.setNeedsDisplay()
        positionSelectionBar()
    }

    private func positionSelectionBar() {
        guard let box = selectionBox, selection?.drag == nil else {
            selectionBar.isHidden = true
            return
        }
        let r = pageView.convert(box, to: view)
        let size = selectionBar.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        let x = min(max(8, r.minX), view.bounds.width - size.width - 8)
        let y = r.minY - size.height - 8 > 8 ? r.minY - size.height - 8 : min(r.maxY + 8, view.bounds.height - size.height - 8)
        selectionBar.frame = CGRect(x: x, y: y, width: size.width, height: size.height)
        selectionBar.isHidden = false
    }

    // MARK: undo

    private func push(_ op: UndoOp) {
        undoStack.append(op)
        if undoStack.count > 300 { undoStack.removeFirst() }
        redoStack = []
        publishUndo()
    }

    private func publishUndo() {
        model?.canUndo = !undoStack.isEmpty
        model?.canRedo = !redoStack.isEmpty
    }

    /// Undo removes what an entry added and brings back what it removed,
    /// under new ids (a removed id stays removed everywhere).
    private func apply(_ op: UndoOp, inverse: Bool) -> UndoOp? {
        guard let model, model.notebook?.pages[op.page] != nil else { return nil }
        if op.page != pageID { model.show(op.page) }
        let out = inverse ? op.added : op.removed
        let inn = Ink.reid(inverse ? op.removed : op.added)
        let present = Set(model.notebook?.pages[op.page]?.strokes.map(\.id) ?? [])
        commit(op.page, added: inn, removed: out.map(\.id).filter { present.contains($0) })
        clearSelection()
        var next = op
        if inverse { next.removed = inn } else { next.added = inn }
        return next
    }

    func undo() {
        while let op = undoStack.popLast() {
            if let next = apply(op, inverse: true) {
                redoStack.append(next)
                break
            }
        }
        publishUndo()
    }

    func redo() {
        while let op = redoStack.popLast() {
            if let next = apply(op, inverse: false) {
                undoStack.append(next)
                break
            }
        }
        publishUndo()
    }

    // MARK: others' strokes as they're written

    func remoteBegan(_ id: String) {
        remoteActive.insert(id)
        refreshInk()
        if let s = pageStrokes.first(where: { $0.id == id }) { live.invalidate(page: InkTiledView.box(s)) }
    }

    func remoteMoved(_ id: String) {
        guard remoteActive.contains(id), let s = pageStrokes.first(where: { $0.id == id }) else { return }
        live.invalidate(page: InkTiledView.box(s))
    }

    func remoteEnded(_ id: String) {
        guard remoteActive.remove(id) != nil else { return }
        if let s = pageStrokes.first(where: { $0.id == id }) { keepOnScreen(s) }
        refreshInk()
    }

    // MARK: the live layer

    private func drawLive(_ ctx: CGContext, clip: CGRect) {
        let strokes = pageStrokes
        if !remoteActive.isEmpty {
            for s in strokes where remoteActive.contains(s.id) { PageRenderer.drawStroke(s, in: ctx, clip: clip) }
        }
        for s in finishing.values.sorted(by: { $0.z < $1.z }) { PageRenderer.drawStroke(s, in: ctx, clip: clip) }
        if let d = drawing {
            switch d.kind {
            case .ink:
                if let line = d.straight {
                    PageRenderer.drawStroke(line, in: ctx, clip: clip)
                } else if var s = d.stroke {
                    s.pts += d.predicted
                    PageRenderer.drawStroke(s, in: ctx, clip: clip)
                }
            case .shape:
                if let s = d.stroke { PageRenderer.drawStroke(s, in: ctx, clip: clip) }
            default:
                break
            }
        }
        let blue = UIColor(red: 40 / 255, green: 110 / 255, blue: 230 / 255, alpha: 0.9).cgColor
        let k = max(0.01, scroll.zoomScale)
        if let e = eraserAt {
            ctx.setStrokeColor(UIColor(white: 0.31, alpha: 0.8).cgColor)
            ctx.setLineWidth(1.5 / k)
            ctx.strokeEllipse(in: CGRect(x: e.x - e.r, y: e.y - e.r, width: e.r * 2, height: e.r * 2))
        }
        if let poly = lasso, poly.count > 1 {
            ctx.saveGState()
            ctx.setLineDash(phase: 0, lengths: [6 / k, 5 / k])
            ctx.setStrokeColor(blue)
            ctx.setLineWidth(1.5 / k)
            ctx.addLines(between: poly.map { CGPoint(x: $0[0], y: $0[1]) })
            ctx.strokePath()
            ctx.restoreGState()
        }
        if let sel = selection {
            if let drag = sel.drag {
                let (dx, dy) = drag
                for s in selected {
                    var c = s
                    c.pts = s.pts.map { p in p.count >= 2 ? [p[0] + dx, p[1] + dy] + p.dropFirst(2) : p }
                    PageRenderer.drawStroke(c, in: ctx, clip: clip)
                }
            }
            if let b = selectionBox {
                ctx.saveGState()
                ctx.setLineDash(phase: 0, lengths: [5 / k, 4 / k])
                ctx.setStrokeColor(blue)
                ctx.setLineWidth(1.2 / k)
                ctx.stroke(b)
                ctx.restoreGState()
            }
        }
    }

    // MARK: the Pencil's double-tap and squeeze

    func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
        pencilAction(UIPencilInteraction.preferredTapAction)
    }

    @available(iOS 17.5, *)
    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
        pencilAction(UIPencilInteraction.preferredTapAction)
    }

    @available(iOS 17.5, *)
    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
        if squeeze.phase == .ended { pencilAction(UIPencilInteraction.preferredSqueezeAction) }
    }

    /// What the Pencil's double-tap (or squeeze) does, as set in Settings ›
    /// Apple Pencil.
    private func pencilAction(_ action: UIPencilPreferredAction) {
        guard let model else { return }
        if action == .switchEraser {
            model.toggleEraser()
        } else if action == .switchPrevious {
            model.switchToPreviousTool()
        } else if action != .ignore {
            model.toggleEraser()
        }
    }

    // MARK: cursor on the computer

    private func cursor(at p: CGPoint) {
        let t = CACurrentMediaTime()
        guard t - lastCursor > 1 / 30 else { return }
        lastCursor = t
        model?.sendCursor(p)
    }

    @objc private func hovered(_ g: UIHoverGestureRecognizer) {
        switch g.state {
        case .began, .changed: cursor(at: g.location(in: pageView))
        default: model?.sendCursor(nil)
        }
    }

    #if DEBUG
    /// CI (DemoLaunch -openpadInkTest): every tool, through the same code as
    /// the Pencil. Draws on the current page: a blue pen stroke, a
    /// highlighter stroke, a box; erases the pen stroke and undoes that; then
    /// lassos the box and moves it 50 right and down.
    func runInkTest() {
        guard let model else { return }
        func stroke(_ pts: [(Double, Double)], pressure: Double? = 0.6) {
            let samples = pts.map { p in
                Sample(x: p.0, y: p.1, raw: pressure, screen: pageView.convert(CGPoint(x: p.0, y: p.1), to: view))
            }
            guard let first = samples.first else { return }
            began(first, pencil: true)
            for s in samples.dropFirst() { moved([s], predicted: [], pencil: true) }
            ended(pencil: true, cancelled: false)
        }
        model.setTool(.pen)
        model.pickColor("#1f5fd6")
        model.width = 6.5
        stroke((0...40).map { i in (150 + Double(i) * 10, 1100 + sin(Double(i) / 4) * 30) })
        model.setTool(.highlighter)
        model.pickColor(Ink.colors[0])
        stroke((0...30).map { i in (150 + Double(i) * 12, 1180) }, pressure: nil)
        model.setTool(.shape)
        model.shape = .rect
        model.width = 3.5
        stroke([(600, 300), (700, 350), (800, 400)])
        model.setTool(.eraser)
        stroke([(300, 1000), (300, 1070), (300, 1140)], pressure: nil)
        undo()
        model.setTool(.lasso)
        stroke([(580, 280), (820, 280), (820, 420), (580, 420), (580, 285)], pressure: nil)
        stroke([(700, 350), (720, 370), (750, 400)], pressure: nil)
        model.setTool(.pen)
        model.pickColor(Ink.colors[0])
    }
    #endif

    /// The tool changed (from the toolbar or the Pencil).
    func toolChanged() {
        if model?.tool != .lasso { clearSelection() }
    }
}
