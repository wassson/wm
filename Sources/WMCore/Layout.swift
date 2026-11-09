import CoreGraphics

/// Hyprland-style "dwindle" layout: each window takes part of the remaining space,
/// splitting along the longer side, and the rest spirals into the other part.
///
/// Split `i` divides the remaining area between window `i` (first part: left or top)
/// and windows `i+1...` (second part). Its ratio is window `i`'s share, 0.5 by default.
///
/// Rects use the Accessibility coordinate space (origin top-left, y grows down),
/// so the first window lands at the left/top.
public enum Dwindle {
    public enum Axis: Equatable, Sendable {
        /// Side by side: the split moves left/right and changes widths.
        case horizontal
        /// Stacked: the split moves up/down and changes heights.
        case vertical
    }

    public static let minRatio = 0.1
    public static let maxRatio = 0.9

    /// The direction of each split (`count - 1` of them). Decided from the even 50/50
    /// layout so resizing never flips a split and makes windows jump around.
    public static func axes(count: Int, in screen: CGRect, gapsIn: CGFloat, gapsOut: Gaps) -> [Axis] {
        guard count > 1 else { return [] }
        var area = inset(screen, gapsOut)
        var result: [Axis] = []
        for _ in 0..<(count - 1) {
            let axis: Axis = area.width >= area.height ? .horizontal : .vertical
            result.append(axis)
            area = split(area, axis: axis, ratio: 0.5, gap: gapsIn).rest
        }
        return result
    }

    public static func layout(count: Int, in screen: CGRect, gapsIn: CGFloat, gapsOut: Gaps,
                              ratios: [Double] = []) -> [CGRect] {
        guard count > 0 else { return [] }
        let splitAxes = axes(count: count, in: screen, gapsIn: gapsIn, gapsOut: gapsOut)
        var area = inset(screen, gapsOut)
        var frames: [CGRect] = []
        frames.reserveCapacity(count)

        for (index, axis) in splitAxes.enumerated() {
            let ratio = index < ratios.count ? clamp(ratios[index]) : 0.5
            let parts = split(area, axis: axis, ratio: ratio, gap: gapsIn)
            frames.append(parts.first)
            area = parts.rest
        }
        frames.append(area)
        return frames
    }

    /// The divider beside window `index` on `axis`: the window's own split when it runs
    /// that way, otherwise the nearest enclosing split that does. Nil if there's none
    /// (nothing next to the window in that direction).
    public static func split(beside index: Int, count: Int, axis: Axis, axes: [Axis]) -> Int? {
        guard index >= 0, index < count, axes.count == count - 1 else { return nil }
        if index < count - 1, axes[index] == axis { return index }
        for j in stride(from: min(index, count - 1) - 1, through: 0, by: -1) where axes[j] == axis {
            return j
        }
        return nil
    }

    public static func clamp(_ ratio: Double) -> Double { min(max(ratio, minRatio), maxRatio) }

    private static func inset(_ screen: CGRect, _ gaps: Gaps) -> CGRect {
        CGRect(x: screen.minX + gaps.left, y: screen.minY + gaps.top,
               width: screen.width - gaps.left - gaps.right,
               height: screen.height - gaps.top - gaps.bottom)
    }

    private static func split(_ area: CGRect, axis: Axis, ratio: Double, gap: CGFloat) -> (first: CGRect, rest: CGRect) {
        switch axis {
        case .horizontal:
            let w = ((area.width - gap) * ratio).rounded(.down)
            return (CGRect(x: area.minX, y: area.minY, width: w, height: area.height),
                    CGRect(x: area.minX + w + gap, y: area.minY, width: area.width - w - gap, height: area.height))
        case .vertical:
            let h = ((area.height - gap) * ratio).rounded(.down)
            return (CGRect(x: area.minX, y: area.minY, width: area.width, height: h),
                    CGRect(x: area.minX, y: area.minY + h + gap, width: area.width, height: area.height - h - gap))
        }
    }
}
