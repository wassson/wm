import AppKit
import WMCore

/// A transparent, click-through overlay that draws the active-window border
/// just outside the focused window's frame (in the gap, like Hyprland).
@MainActor
final class BorderWindow: NSWindow {
    private var borderView: BorderView { contentView as! BorderView }

    convenience init() {
        self.init(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        contentView = BorderView(frame: .zero)
    }

    /// AppKit nudges windows out from under the menu bar. The border has to sit exactly
    /// around its window (which may touch the menu bar), so take frames as given.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// - Parameters:
    ///   - windowFrame: the focused window's frame in AppKit coordinates.
    ///   - radii: corner radii of the border's outer edge.
    func show(around windowFrame: NSRect, width: Double, radii: CornerRadii, color: RGBA) {
        // Only touch what changed: each property change rebuilds the shape layer's path.
        if borderView.lineWidth != width { borderView.lineWidth = width }
        if borderView.radii != radii { borderView.radii = radii }
        if borderView.rgba != color {
            borderView.rgba = color
            borderView.color = NSColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
        }

        let frame = windowFrame.insetBy(dx: -width, dy: -width)
        if self.frame != frame { setFrame(frame, display: false) }
        borderView.layoutSubtreeIfNeeded()
        if !isVisible { orderFrontRegardless() }
    }
}

private final class BorderView: NSView {
    var lineWidth: Double = 2 { didSet { needsLayout = true } }
    var radii = CornerRadii(uniform: 12) { didSet { needsLayout = true } }
    var color: NSColor = .systemBlue { didSet { needsLayout = true } }
    var rgba: RGBA?

    private let shape = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never  // nothing is drawn with draw(_:)
        shape.fillColor = nil
        layer?.addSublayer(shape)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        // The view is laid out once before the window has a size; a path in an empty
        // or inverted rect would hand NaNs to NSBezierPath, which throws.
        guard bounds.width > lineWidth * 2, bounds.height > lineWidth * 2 else {
            shape.path = nil
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)  // no implicit animation when following a drag
        // Stroke centered in the ring between the overlay's edge and the window's edge,
        // so each corner's radius shrinks by half the line width.
        let inset = lineWidth / 2
        shape.frame = bounds
        shape.lineWidth = lineWidth
        shape.strokeColor = color.cgColor
        shape.path = NSBezierPath.roundedRect(bounds.insetBy(dx: inset, dy: inset), radii: CornerRadii(
            topLeft: radii.topLeft - inset, topRight: radii.topRight - inset,
            bottomLeft: radii.bottomLeft - inset, bottomRight: radii.bottomRight - inset)).cgPath
        CATransaction.commit()
    }
}

extension NSBezierPath {
    /// A rectangle with an individual radius per corner (AppKit coordinates: y up).
    static func roundedRect(_ r: NSRect, radii: CornerRadii) -> NSBezierPath {
        let limit = max(min(r.width, r.height) / 2, 0)
        func clamp(_ v: Double) -> CGFloat { CGFloat(min(max(v, 0), limit)) }
        let tl = clamp(radii.topLeft), tr = clamp(radii.topRight)
        let bl = clamp(radii.bottomLeft), br = clamp(radii.bottomRight)

        let path = NSBezierPath()
        path.move(to: NSPoint(x: r.minX + bl, y: r.minY))
        path.line(to: NSPoint(x: r.maxX - br, y: r.minY))
        path.appendArc(withCenter: NSPoint(x: r.maxX - br, y: r.minY + br), radius: br, startAngle: 270, endAngle: 360)
        path.line(to: NSPoint(x: r.maxX, y: r.maxY - tr))
        path.appendArc(withCenter: NSPoint(x: r.maxX - tr, y: r.maxY - tr), radius: tr, startAngle: 0, endAngle: 90)
        path.line(to: NSPoint(x: r.minX + tl, y: r.maxY))
        path.appendArc(withCenter: NSPoint(x: r.minX + tl, y: r.maxY - tl), radius: tl, startAngle: 90, endAngle: 180)
        path.line(to: NSPoint(x: r.minX, y: r.minY + bl))
        path.appendArc(withCenter: NSPoint(x: r.minX + bl, y: r.minY + bl), radius: bl, startAngle: 180, endAngle: 270)
        path.close()
        return path
    }
}
