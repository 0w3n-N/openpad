import OpenPadCore
import PencilKit
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// Paper and PDF pages, drawn in tiles so they stay sharp at any zoom.
final class TiledPageView: UIView {
    struct Content {
        var page: Page
        var pdfURL: URL?
    }

    override class var layerClass: AnyClass { CATiledLayer.self }

    private let lock = NSLock()
    private var _content: Content?
    var content: Content? {
        get { lock.lock(); defer { lock.unlock() }; return _content }
        set { lock.lock(); _content = newValue; lock.unlock(); setNeedsDisplay() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        let tiled = layer as! CATiledLayer
        tiled.levelsOfDetail = 4
        tiled.levelsOfDetailBias = 4
        tiled.tileSize = CGSize(width: 512, height: 512)
        backgroundColor = .white
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // Called on background threads, one tile at a time.
    override func draw(_ rect: CGRect) {
        guard let content, let ctx = UIGraphicsGetCurrentContext(), bounds.width > 0 else { return }
        let page = content.page
        let k = bounds.width / CGFloat(page.w)
        ctx.saveGState()
        ctx.scaleBy(x: k, y: k)
        PageRenderer.drawPaper(page, in: ctx, scale: k)
        if let url = content.pdfURL, let sha = page.bg?.pdf, let n = page.bg?.n,
           let pdfPage = PDFAssets.shared.document(sha, url: url)?.page(at: n) {
            PageRenderer.drawPDFPage(pdfPage, in: ctx, rect: CGRect(x: 0, y: 0, width: page.w, height: page.h))
        }
        ctx.restoreGState()
    }
}

/// Sees the Pencil while PencilKit draws (for the cursor and live preview on
/// the computer), without taking any touches away from it.
final class PenObserver: UIGestureRecognizer {
    enum Phase { case began, moved, ended }
    var onPencil: ((Phase, [CGPoint]) -> Void)?

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) { report(.began, touches, event) }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) { report(.moved, touches, event) }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        report(.ended, touches, event)
        state = .failed
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        report(.ended, touches, event)
        state = .failed
    }

    private func report(_ phase: Phase, _ touches: Set<UITouch>, _ event: UIEvent) {
        guard let t = touches.first(where: { $0.type == .pencil }), let view else { return }
        let all = event.coalescedTouches(for: t) ?? [t]
        onPencil?(phase, all.map { $0.location(in: view) })
    }
}

/// One page: a PencilKit canvas over its paper or PDF. Strokes drawn here
/// become OpenPad strokes (AppModel.localStrokes); strokes from elsewhere
/// (sync, guests) are shown by rebuilding the drawing from the page.
@MainActor
final class PageCanvasController: UIViewController, PKCanvasViewDelegate, UIGestureRecognizerDelegate {
    let canvas = PKCanvasView()
    private let backdrop = UIView()
    private let tiled = TiledPageView()
    private let imageView = UIImageView()
    private let toolPicker = PKToolPicker()
    weak var model: AppModel?

    private(set) var pageID: String?
    private var pageSize = CGSize(width: 1000, height: 1294)
    private var ids: [String] = []  // OpenPad id of each stroke in canvas.drawing
    private var prints: [String] = []  // and its fingerprint
    private var cache: [String: PKStroke] = [:]  // "<id>.<points>" -> converted stroke
    private var applying = false
    private(set) var drawingActive = false
    private var reloadPending = false
    private var fitted = true
    private var lastSize: CGSize = .zero
    private var lastCursor: TimeInterval = 0

    init(model: AppModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(white: 0.12, alpha: 1)
        canvas.frame = view.bounds
        canvas.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        canvas.delegate = self
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.overrideUserInterfaceStyle = .light  // ink colors as drawn, not adapted to dark mode
        canvas.alwaysBounceVertical = true
        canvas.showsVerticalScrollIndicator = true
        canvas.contentInsetAdjustmentBehavior = .never
        canvas.tool = PKInkingTool(.pen, color: .black, width: 4)
        view.addSubview(canvas)

        backdrop.isUserInteractionEnabled = false
        backdrop.backgroundColor = .white
        backdrop.layer.shadowColor = UIColor.black.cgColor
        backdrop.layer.shadowOpacity = 0.35
        backdrop.layer.shadowRadius = 12
        tiled.frame = backdrop.bounds
        tiled.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        imageView.frame = backdrop.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        imageView.contentMode = .scaleToFill
        backdrop.addSubview(tiled)
        backdrop.addSubview(imageView)
        canvas.insertSubview(backdrop, at: 0)

        let observer = PenObserver(target: nil, action: nil)
        observer.delegate = self
        observer.onPencil = { [weak self] phase, points in self?.pencil(phase, points) }
        canvas.addGestureRecognizer(observer)
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:)))
        canvas.addGestureRecognizer(hover)

        applySettings()
        if let model, let id = model.pageID { show(pageID: id, refit: true, from: model) }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        toolPicker.setVisible(true, forFirstResponder: canvas)
        toolPicker.addObserver(canvas)
        canvas.becomeFirstResponder()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        toolPicker.setVisible(false, forFirstResponder: canvas)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if view.bounds.size != lastSize {
            lastSize = view.bounds.size
            if fitted { fit() } else { updateLayout() }
        }
    }

    func applySettings() {
        canvas.drawingPolicy = (model?.fingerDrawing ?? false) ? .anyInput : .pencilOnly
    }

    // MARK: pages

    /// Show a page of the open notebook (or refresh the current one).
    func show(pageID: String, refit: Bool, from model: AppModel) {
        guard let page = model.notebook?.pages[pageID] else { return }
        let changed = pageID != self.pageID
        self.pageID = pageID
        pageSize = CGSize(width: page.w, height: page.h)
        configureBackground(page)
        if changed { cache.removeAll(keepingCapacity: true) }
        rebuild(page)
        if refit || changed { fit() } else { updateLayout() }
    }

    private func configureBackground(_ page: Page) {
        guard let model else { return }
        let pdfURL = page.bg?.pdf.map { model.store.assetURL($0) }
        tiled.content = TiledPageView.Content(page: page.metaOnly, pdfURL: pdfURL)
        if let sha = page.bg?.img {
            imageView.image = PDFAssets.shared.image(sha, store: model.store)
        } else if page.bg?.live == true {
            imageView.image = model.liveFrame
        } else {
            imageView.image = nil
        }
        imageView.isHidden = imageView.image == nil
        backdrop.backgroundColor = page.bg?.live == true ? .black : .white
    }

    /// A new frame of the live desktop window.
    func liveFrameChanged(_ image: UIImage?) {
        guard let model, let id = pageID, model.notebook?.pages[id]?.bg?.live == true else { return }
        imageView.image = image
        imageView.isHidden = image == nil
    }

    /// The model changed this page (sync, guests, page settings).
    func reloadFromModel() {
        guard let model, let id = pageID else { return }
        if drawingActive {
            reloadPending = true  // never interrupt a stroke in progress
            return
        }
        guard let page = model.notebook?.pages[id] else { return }
        if CGSize(width: page.w, height: page.h) != pageSize {
            pageSize = CGSize(width: page.w, height: page.h)
            fit()
        }
        configureBackground(page)
        rebuild(page)
    }

    private func rebuild(_ page: Page) {
        var strokes: [PKStroke] = []
        var next: [String: PKStroke] = [:]
        strokes.reserveCapacity(page.strokes.count)
        for s in page.strokes {
            let key = "\(s.id).\(s.pts.count)"
            let pk = cache[key] ?? InkConverter.pkStroke(s)
            next[key] = pk
            strokes.append(pk)
        }
        cache = next
        applying = true
        canvas.drawing = PKDrawing(strokes: strokes)
        ids = page.strokes.map(\.id)
        prints = canvas.drawing.strokes.map(InkConverter.fingerprint)
        applying = false
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
        canvas.minimumZoomScale = max(0.05, min(byWidth, byHeight) * 0.6)
        canvas.maximumZoomScale = max(s * 8, 4)
        canvas.zoomScale = s
        fitted = true
        updateLayout()
        canvas.contentOffset = CGPoint(x: -canvas.contentInset.left, y: -canvas.contentInset.top)
    }

    private func updateLayout() {
        let z = canvas.zoomScale
        let size = CGSize(width: pageSize.width * z, height: pageSize.height * z)
        canvas.contentSize = size
        backdrop.frame = CGRect(origin: .zero, size: size)
        let insetX = max(16, (canvas.bounds.width - size.width) / 2)
        // Portrait pages start at the top, like paper (the tool palette sits
        // at the bottom); wide pages are centered.
        let spare = max(0, canvas.bounds.height - size.height)
        let top = pageSize.height > pageSize.width ? min(16, spare) : max(16, spare / 2)
        let bottom = max(16, spare - top)
        canvas.contentInset = UIEdgeInsets(top: top, left: insetX, bottom: bottom, right: insetX)
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        fitted = false
        updateLayout()
    }

    func resetZoom() { fit() }

    // MARK: drawing

    func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
        drawingActive = true
    }

    func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
        drawingActive = false
        if reloadPending {
            reloadPending = false
            // Let PencilKit finish committing the stroke first.
            DispatchQueue.main.async { [weak self] in self?.reloadFromModel() }
        }
    }

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        guard !applying, let pageID else { return }
        if let split = InkConverter.split(canvas.drawing) {
            applying = true
            canvas.drawing = split
            applying = false
        }
        let now = canvas.drawing.strokes
        // Match strokes to the previous ones by fingerprint; what doesn't match
        // was added (new ids) or removed.
        var pool: [String: [String]] = [:]
        for (fp, id) in zip(prints, ids) { pool[fp, default: []].append(id) }
        var newIDs: [String] = []
        var newPrints: [String] = []
        var added: [Stroke] = []
        for pk in now {
            let fp = InkConverter.fingerprint(pk)
            if var list = pool[fp], !list.isEmpty {
                newIDs.append(list.removeFirst())
                pool[fp] = list
            } else {
                let id = newID()
                newIDs.append(id)
                added.append(InkConverter.stroke(from: pk, id: id, z: nextZ()))
            }
            newPrints.append(fp)
        }
        let removed = pool.values.flatMap { $0 }
        ids = newIDs
        prints = newPrints
        for s in added {
            cache["\(s.id).\(s.pts.count)"] = InkConverter.pkStroke(s)
        }
        if !added.isEmpty || !removed.isEmpty {
            model?.localStrokes(page: pageID, added: added, removed: removed)
        }
    }

    // MARK: cursor and live preview

    private var previewID: String?
    private var previewPending: [[Double]] = []
    private var previewSent: TimeInterval = 0

    private func pencil(_ phase: PenObserver.Phase, _ points: [CGPoint]) {
        guard let last = points.last else { return }
        let z = max(0.01, canvas.zoomScale)
        let pageXY = points.map { [(Double($0.x / z) * 100).rounded() / 100, (Double($0.y / z) * 100).rounded() / 100, 0.5] }
        let inking = canvas.tool is PKInkingTool  // not the eraser or lasso
        switch phase {
        case .began:
            cursor(at: last)
            previewID = inking ? newID() : nil
            previewPending = pageXY
            previewSent = 0
        case .moved:
            cursor(at: last)
            guard let id = previewID else { return }
            previewPending += pageXY
            let t = CACurrentMediaTime()
            if t - previewSent > 1 / 30 {
                previewSent = t
                model?.sendPreview(id: id, points: previewPending, tool: canvas.tool, end: false)
                previewPending = []
            }
        case .ended:
            if let id = previewID {
                model?.sendPreview(id: id, points: previewPending + pageXY, tool: canvas.tool, end: true)
            }
            previewID = nil
            previewPending = []
            model?.sendCursor(nil)
        }
    }

    private func cursor(at point: CGPoint) {
        let t = CACurrentMediaTime()
        guard t - lastCursor > 1 / 30 else { return }
        lastCursor = t
        let z = max(0.01, canvas.zoomScale)
        model?.sendCursor(CGPoint(x: point.x / z, y: point.y / z))
    }

    @objc private func hovered(_ g: UIHoverGestureRecognizer) {
        switch g.state {
        case .began, .changed: cursor(at: g.location(in: canvas))
        default: model?.sendCursor(nil)
        }
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }

    // MARK: undo

    func undo() { canvas.undoManager?.undo() }
    func redo() { canvas.undoManager?.redo() }
}
