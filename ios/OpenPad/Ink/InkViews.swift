import OpenPadCore
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// The page's finished ink, drawn in tiles like the paper (bounds in page
/// units, scaled by the zoom), so it stays sharp at any zoom. Only the parts
/// that changed are redrawn.
final class InkTiledView: UIView {
    /// Tiles appear at once instead of fading in.
    final class Layer: CATiledLayer {
        override class func fadeDuration() -> CFTimeInterval { 0 }
    }

    override class var layerClass: AnyClass { Layer.self }

    private struct Item {
        let stroke: Stroke
        let box: CGRect
    }

    // Read by tiles drawing on background threads.
    private let lock = NSLock()
    private var items: [Item] = []
    private var hidden: Set<String> = []
    // Main thread only: what each stroke looked like when last drawn.
    private var known: [String: (count: Int, box: CGRect)] = [:]

    override init(frame: CGRect) {
        super.init(frame: frame)
        let tiled = layer as! CATiledLayer
        tiled.levelsOfDetail = 4
        tiled.levelsOfDetailBias = 4
        tiled.tileSize = CGSize(width: 512, height: 512)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    static func box(_ s: Stroke) -> CGRect {
        let b = Ink.bounds(s)
        return CGRect(x: b.0, y: b.1, width: b.2 - b.0, height: b.3 - b.1)
    }

    /// Show these strokes (in stacking order) except the hidden ones.
    func show(_ strokes: [Stroke], hidden newHidden: Set<String>) {
        let newItems = strokes.map { Item(stroke: $0, box: Self.box($0)) }
        var next: [String: (count: Int, box: CGRect)] = [:]
        var dirty: [CGRect] = []
        for it in newItems {
            let id = it.stroke.id
            next[id] = (it.stroke.pts.count, it.box)
            if let old = known[id] {
                if old.count != it.stroke.pts.count || old.box != it.box { dirty += [old.box, it.box] }
            } else {
                dirty.append(it.box)
            }
        }
        for (id, old) in known where next[id] == nil { dirty.append(old.box) }
        lock.lock()
        let oldHidden = hidden
        items = newItems
        hidden = newHidden
        lock.unlock()
        for id in oldHidden.symmetricDifference(newHidden) {
            if let b = next[id]?.box ?? known[id]?.box { dirty.append(b) }
        }
        known = next
        if dirty.count > 200 {
            setNeedsDisplay()
        } else {
            for r in dirty { setNeedsDisplay(r.insetBy(dx: -2, dy: -2)) }
        }
    }

    /// Forget everything (another page): the next show draws it all.
    func reset() {
        lock.lock()
        items = []
        hidden = []
        lock.unlock()
        known = [:]
        setNeedsDisplay()
    }

    // Called on background threads, one tile at a time.
    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        lock.lock()
        let items = self.items, hidden = self.hidden
        lock.unlock()
        for it in items where it.box.intersects(rect) && !hidden.contains(it.stroke.id) {
            PageRenderer.drawStroke(it.stroke, in: ctx, clip: rect)
        }
    }
}

/// What's happening right now, drawn over the page in screen coordinates:
/// the stroke under the Pencil, others' strokes still being written, the
/// eraser, the lasso and the selection. `drawContent` draws in page units.
final class LiveInkView: UIView {
    weak var pageView: UIView?
    var drawContent: ((CGContext, CGRect) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Page units to this view's coordinates.
    var pageTransform: CGAffineTransform {
        guard let pageView else { return .identity }
        let o = pageView.convert(CGPoint.zero, to: self)
        let x = pageView.convert(CGPoint(x: 1, y: 0), to: self)
        let k = x.x - o.x
        return CGAffineTransform(a: k, b: 0, c: 0, d: k, tx: o.x, ty: o.y)
    }

    /// Redraw the part of the screen over this page rectangle.
    func invalidate(page r: CGRect) {
        guard !r.isNull, !r.isInfinite else { return setNeedsDisplay() }
        setNeedsDisplay(r.applying(pageTransform).insetBy(dx: -3, dy: -3))
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext(), let drawContent else { return }
        let t = pageTransform
        ctx.concatenate(t)
        drawContent(ctx, rect.applying(t.inverted()))
    }
}

/// Hands the canvas the touches that draw: the Pencil's, and one finger's
/// when drawing with a finger is on. A second finger cancels a finger stroke
/// (that's scrolling or zooming); other touches are left to the scroll view.
final class InkGesture: UIGestureRecognizer {
    var onBegan: ((UITouch, UIEvent) -> Void)?
    var onMoved: ((UITouch, UIEvent) -> Void)?
    var onEnded: ((UITouch, UIEvent?, Bool) -> Void)?  // true: cancelled
    private(set) var touch: UITouch?

    var fingers = false {
        didSet {
            allowedTouchTypes = fingers
                ? [NSNumber(value: UITouch.TouchType.pencil.rawValue), NSNumber(value: UITouch.TouchType.direct.rawValue)]
                : [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        }
    }

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if let current = touch {
            if current.type == .direct, touches.contains(where: { $0.type == .direct }) {
                touch = nil
                onEnded?(current, event, true)
                state = .cancelled
                return
            }
            for t in touches { ignore(t, for: event) }
            return
        }
        // The Pencil wins over a finger that touched at the same moment.
        guard let t = touches.first(where: { $0.type == .pencil }) ?? touches.first else { return }
        for other in touches where other !== t { ignore(other, for: event) }
        touch = t
        onBegan?(t, event)
        state = .began
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let t = touch, touches.contains(t) else { return }
        onMoved?(t, event)
        state = .changed
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let t = touch, touches.contains(t) else { return }
        touch = nil
        onEnded?(t, event, false)
        state = .ended
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let t = touch, touches.contains(t) else { return }
        touch = nil
        onEnded?(t, event, true)
        state = .cancelled
    }

    override func reset() {
        super.reset()
        if let t = touch {
            touch = nil
            onEnded?(t, nil, true)
        }
    }
}
