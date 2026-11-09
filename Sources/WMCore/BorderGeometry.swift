import CoreGraphics

public struct CornerRadii: Equatable, Sendable {
    public var topLeft: Double
    public var topRight: Double
    public var bottomLeft: Double
    public var bottomRight: Double

    public init(topLeft: Double, topRight: Double, bottomLeft: Double, bottomRight: Double) {
        self.topLeft = topLeft
        self.topRight = topRight
        self.bottomLeft = bottomLeft
        self.bottomRight = bottomRight
    }

    public init(uniform r: Double) {
        self.init(topLeft: r, topRight: r, bottomLeft: r, bottomRight: r)
    }
}

public enum BorderGeometry {
    /// Corner radii for the border's *outer* edge.
    ///
    /// Normally each corner is the window's radius plus the border width, so the
    /// border hugs the window. A bottom corner whose border sits in the matching
    /// bottom corner of the display instead follows the display's rounded corner,
    /// concentric with it (the display radius minus the distance from the edge).
    ///
    /// All rects are in Accessibility coordinates (origin top-left, y grows down).
    ///
    /// - Parameters:
    ///   - displayRadius: the display's physical corner radius, or nil to disable matching.
    ///   - proximity: how close (in points) the border's outer edge must be to both
    ///     screen edges for that corner to follow the display.
    public static func outerRadii(
        windowFrame: CGRect,
        screenFrame: CGRect,
        windowRadius: Double,
        borderWidth: Double,
        displayRadius: Double?,
        proximity: Double
    ) -> CornerRadii {
        var radii = CornerRadii(uniform: windowRadius + borderWidth)
        guard let displayRadius, displayRadius > 0 else { return radii }

        let outer = windowFrame.insetBy(dx: -borderWidth, dy: -borderWidth)
        let fromBottom = screenFrame.maxY - outer.maxY
        let fromLeft = outer.minX - screenFrame.minX
        let fromRight = screenFrame.maxX - outer.maxX

        func concentric(_ a: Double, _ b: Double) -> Double? {
            guard a >= -1, b >= -1, a <= proximity, b <= proximity else { return nil }
            return max(displayRadius - max(a, b, 0), 0)
        }
        if let r = concentric(fromLeft, fromBottom) { radii.bottomLeft = r }
        if let r = concentric(fromRight, fromBottom) { radii.bottomRight = r }
        return radii
    }
}
