/// A pip position on a 3×3 domino face (column, row ∈ 0...2; row 0 is the top).
public struct Pip: Hashable, Sendable {
    public let column: Int
    public let row: Int
    public init(_ column: Int, _ row: Int) {
        self.column = column
        self.row = row
    }
}

/// Standard domino pip arrangements, used for the menu bar workspace indicator.
public enum Domino {
    public static func pips(for value: Int) -> [Pip] {
        let center = Pip(1, 1)
        let corners = [Pip(0, 0), Pip(2, 0), Pip(0, 2), Pip(2, 2)]
        let sides = [Pip(0, 1), Pip(2, 1)]

        switch value {
        case 1: return [center]
        case 2: return [Pip(2, 0), Pip(0, 2)]
        case 3: return [Pip(2, 0), center, Pip(0, 2)]
        case 4: return corners
        case 5: return corners + [center]
        case 6: return corners + sides
        case 7: return corners + sides + [center]
        case 8: return corners + sides + [Pip(1, 0), Pip(1, 2)]
        case 9: return corners + sides + [Pip(1, 0), Pip(1, 2), center]
        default: return []
        }
    }
}
