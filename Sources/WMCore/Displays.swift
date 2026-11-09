import CoreGraphics

/// How workspaces map onto displays. Displays are indexed in `order` (external displays
/// first, built-in last), and workspaces are dealt out round-robin: with a laptop and one
/// external display, odd workspaces go to the external display and even ones to the
/// laptop. Each display always shows one of its own workspaces.
public enum DisplayAssignment {
    /// Display indices in assignment order: external displays first, then built-in ones,
    /// otherwise keeping the system's order (primary first).
    public static func order(builtIn: [Bool]) -> [Int] {
        builtIn.indices.filter { !builtIn[$0] } + builtIn.indices.filter { builtIn[$0] }
    }

    public static func display(for workspace: Int, displayCount: Int) -> Int {
        (workspace - 1) % max(displayCount, 1)
    }

    /// The workspace each display shows, keyed by display index. Keeps what each display
    /// was showing when that's still valid, otherwise falls back to the display's first
    /// workspace. Displays with no workspace (more displays than workspaces) are left out.
    public static func visible(previous: [Int: Int], displayCount: Int, workspaceCount: Int) -> [Int: Int] {
        var result: [Int: Int] = [:]
        for d in 0..<max(displayCount, 1) {
            if let ws = previous[d], ws <= workspaceCount, display(for: ws, displayCount: displayCount) == d {
                result[d] = ws
            } else if d + 1 <= workspaceCount {
                result[d] = d + 1
            }
        }
        return result
    }

    /// Where to park a window of a hidden workspace: just off a bottom corner of its own
    /// display with one pixel left on it (macOS pulls fully off-screen windows back), on a
    /// side where it doesn't overlap any other display. Rects are in AX coordinates.
    public static func parkingOrigin(display: CGRect, allDisplays: [CGRect], windowSize: CGSize) -> CGPoint {
        let size = CGSize(width: max(windowSize.width, 1), height: max(windowSize.height, 1))
        let candidates = [
            CGPoint(x: display.maxX - 1, y: display.maxY - 1),                    // bottom-right
            CGPoint(x: display.minX - size.width + 1, y: display.maxY - 1),       // bottom-left
            CGPoint(x: display.maxX - 1, y: display.minY - size.height + 1),      // top-right
            CGPoint(x: display.minX - size.width + 1, y: display.minY - size.height + 1),  // top-left
        ]
        let others = allDisplays.filter { $0 != display }
        for origin in candidates {
            let rect = CGRect(origin: origin, size: size)
            if !others.contains(where: { $0.intersects(rect) }) { return origin }
        }
        return candidates[0]
    }

    /// Index of the display containing `point`, if any.
    public static func display(containing point: CGPoint, displays: [CGRect]) -> Int? {
        displays.firstIndex { $0.contains(point) }
    }
}
