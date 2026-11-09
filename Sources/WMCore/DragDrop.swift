import CoreGraphics

public enum DragDrop {
    /// Decides what a drag of a tiled window should do once the mouse is released.
    ///
    /// - Parameters:
    ///   - dragged: the window that was dragged.
    ///   - currentSize: its size now. If it differs from its tile, the user resized
    ///     it (edge drags also move the origin), so it isn't a reposition.
    ///   - cursor: where the mouse was released.
    ///   - tiles: each tiled window's assigned frame.
    /// - Returns: the window to swap places with, or nil to just snap back.
    public static func swapTarget<ID: Hashable>(
        dragged: ID, currentSize: CGSize, cursor: CGPoint, tiles: [ID: CGRect], tolerance: CGFloat = 2
    ) -> ID? {
        guard let home = tiles[dragged],
              abs(home.width - currentSize.width) <= tolerance,
              abs(home.height - currentSize.height) <= tolerance,
              !home.contains(cursor) else { return nil }
        return tiles.first { $0.key != dragged && $0.value.contains(cursor) }?.key
    }
}
