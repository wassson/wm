import CoreGraphics
import Testing
@testable import WMCore

@Suite struct TOMLTests {
    @Test func parsesTablesAndValues() throws {
        let doc = try TOML.parse("""
        # comment
        top = "hi"   # trailing comment
        [a]
        int = 42
        float = 1.5
        flag = true
        list = ["x", 'y',
                "z"]
        "quoted key" = "\\u00e9\\n"
        inline = { k = 1 }
        [a.b]
        c = -3
        """)
        #expect(doc["top"] == .string("hi"))
        let a = try #require(doc["a"]?.table)
        #expect(a["int"] == .integer(42))
        #expect(a["float"] == .float(1.5))
        #expect(a["flag"] == .boolean(true))
        #expect(a["list"] == .array([.string("x"), .string("y"), .string("z")]))
        #expect(a["quoted key"] == .string("é\n"))
        #expect(a["inline"] == .table(["k": .integer(1)]))
        #expect(a["b"]?.table?["c"] == .integer(-3))
    }

    @Test func handlesCRLF() throws {
        let doc = try TOML.parse("[x]\r\ny = 1\r\n")
        #expect(doc["x"]?.table?["y"] == .integer(1))
    }

    @Test func reportsErrorLine() {
        #expect(throws: TOMLError(line: 3, message: "unexpected character 'n'")) {
            try TOML.parse("a = 1\n\nb = nope\n")
        }
    }

    @Test func rejectsDuplicates() {
        #expect(throws: TOMLError.self) { try TOML.parse("a = 1\na = 2") }
    }
}

@Suite struct ConfigTests {
    @Test func defaultFileMatchesBuiltInDefaults() throws {
        let result = try Config.parse(Config.defaultTOML)
        #expect(result.warnings.isEmpty)
        #expect(result.config == Config())
        #expect(result.config.gapsIn == 2)
        #expect(result.config.gapsOut == 2)
        #expect(result.config.workspaceCount == 9)
        #expect(result.config.bindings.count == 58)
    }

    @Test func emptyFileUsesDefaults() throws {
        #expect(try Config.parse("").config == Config())
    }

    @Test func overridesAndWarnings() throws {
        let result = try Config.parse("""
        [general]
        gaps_in = 8
        gaps_out = 4.5
        workspaces = 4
        typo = 1
        [border]
        active_color = "#ff000080"
        [binds]
        "cmd+shift+left" = "focus left"
        "ctrl+5" = "workspace 5"
        """)
        let c = result.config
        #expect(c.gapsIn == 8)
        #expect(c.gapsOut == 4.5)
        #expect(c.workspaceCount == 4)
        #expect(c.activeBorderColor == RGBA(red: 1, green: 0, blue: 0, alpha: 128.0 / 255))
        #expect(c.bindings.count == 2)
        #expect(c.bindings.contains(KeyBinding(chord: KeyChord(modifiers: [.command, .shift], keyCode: 0x7B), action: .focus(.left))))
        #expect(result.warnings.count == 2)  // unknown key + workspace 5 > 4
    }

    @Test func gapsOutAcceptsNumberOrSides() throws {
        #expect(try Config.parse("[general]\ngaps_out = 3").config.gapsOut == Gaps(3))
        #expect(try Config.parse("[general]\ngaps_out = [0, 6, 6, 6]").config.gapsOut == Gaps(top: 0, right: 6, bottom: 6, left: 6))
        #expect(try Config.parse("[general]\ngaps_out = [0, 4]").config.gapsOut == Gaps(top: 0, right: 4, bottom: 0, left: 4))
        #expect(throws: ConfigError.self) { try Config.parse("[general]\ngaps_out = [1, 2, 3, 4, 5]") }
        #expect(throws: ConfigError.self) { try Config.parse("[general]\ngaps_out = [0, -1]") }
    }

    @Test func perAppBorderRadius() throws {
        let c = try Config.parse("""
        [border]
        radius = 14
        [border.app_radius]
        "Rex Beta" = 26
        "com.example.Square" = 0
        """).config
        #expect(c.borderRadius(bundleID: "com.superlogical.rex", appName: "Rex Beta") == 26)
        #expect(c.borderRadius(bundleID: nil, appName: "rex beta") == 26)
        #expect(c.borderRadius(bundleID: "com.example.square", appName: "Square") == 0)
        #expect(c.borderRadius(bundleID: "com.apple.Safari", appName: "Safari") == 14)
        #expect(throws: ConfigError.self) { try Config.parse("[border.app_radius]\n\"Rex\" = \"big\"") }
    }

    @Test func invalidValuesThrow() {
        #expect(throws: ConfigError.self) { try Config.parse("[general]\ngaps_in = -1") }
        #expect(throws: ConfigError.self) { try Config.parse("[general]\nworkspaces = 10") }
        #expect(throws: ConfigError.self) { try Config.parse("[border]\nactive_color = \"blue\"") }
        #expect(throws: ConfigError.self) { try Config.parse("[binds]\n\"hyper+1\" = \"workspace 1\"") }
        #expect(throws: ConfigError.self) { try Config.parse("[binds]\n\"alt+1\" = \"workspace 10\"") }
        #expect(throws: ConfigError.self) { try Config.parse("[binds]\n\"alt+1\" = \"workspace 1\"\n\"option+1\" = \"workspace 2\"") }
    }

    @Test func parsesActions() {
        #expect(Action(parsing: "workspace 3") == .workspace(3))
        #expect(Action(parsing: "movetoworkspace 8") == .moveToWorkspace(8))
        #expect(Action(parsing: "swap Up") == .swap(.up))
        #expect(Action(parsing: "togglefloat") == .toggleFloat)
        #expect(Action(parsing: "movesplit right") == .moveSplit(.right))
        #expect(Action(parsing: "movesplit sideways") == nil)
        #expect(KeyChord(parsing: "cmd+shift+[") == KeyChord(modifiers: [.command, .shift], keyCode: 0x21))
        #expect(Action(parsing: "workspace") == nil)
        #expect(Action(parsing: "focus sideways") == nil)
    }
}

@Suite struct DwindleTests {
    let screen = CGRect(x: 0, y: 25, width: 1000, height: 600)

    @Test func singleWindowFillsScreenMinusOuterGap() {
        let frames = Dwindle.layout(count: 1, in: screen, gapsIn: 2, gapsOut: 2)
        #expect(frames == [CGRect(x: 2, y: 27, width: 996, height: 596)])
    }

    @Test func twoWindowsSplitSideBySideWithInnerGap() {
        let frames = Dwindle.layout(count: 2, in: screen, gapsIn: 2, gapsOut: 2)
        #expect(frames.count == 2)
        #expect(frames[0] == CGRect(x: 2, y: 27, width: 497, height: 596))
        #expect(frames[1].minX - frames[0].maxX == 2)
        #expect(frames[1].maxX == 998)
    }

    @Test func thirdWindowSplitsVertically() {
        let frames = Dwindle.layout(count: 3, in: screen, gapsIn: 2, gapsOut: 2)
        #expect(frames[1].minX == frames[2].minX)
        #expect(frames[2].minY - frames[1].maxY == 2)
        #expect(frames[2].maxY == 623)
    }

    @Test func perSideOuterGaps() {
        let frames = Dwindle.layout(count: 1, in: screen, gapsIn: 6,
                                    gapsOut: Gaps(top: 0, right: 6, bottom: 6, left: 6))
        #expect(frames == [CGRect(x: 6, y: 25, width: 988, height: 594)])
    }

    @Test func ratiosResizeAndNeighboursFill() {
        // Two side-by-side windows, first one at 70%.
        let frames = Dwindle.layout(count: 2, in: screen, gapsIn: 2, gapsOut: 2, ratios: [0.7])
        #expect(frames[0].width == ((996 - 2) * 0.7).rounded(.down))
        #expect(frames[1].minX - frames[0].maxX == 2)
        #expect(frames[1].maxX == 998)  // the other window fills the rest
    }

    @Test func ratiosAreClampedAndDontFlipSplits() {
        let even = Dwindle.axes(count: 3, in: screen, gapsIn: 2, gapsOut: 2)
        #expect(even == [.horizontal, .vertical])
        // An extreme ratio is clamped to 0.9, and split 1 stays vertical even though
        // the remaining area is now taller than it is wide.
        let frames = Dwindle.layout(count: 3, in: screen, gapsIn: 2, gapsOut: 2, ratios: [5, 0.5])
        #expect(frames[0].width == ((996 - 2) * 0.9).rounded(.down))
        #expect(frames[1].minX == frames[2].minX)
    }

    @Test func dividerBesideWindowIsNearestOnAxis() {
        let axes: [Dwindle.Axis] = [.horizontal, .vertical, .horizontal]  // 4 windows
        // Window 0 owns split 0 (side by side) and has no stacked divider next to it.
        #expect(Dwindle.split(beside: 0, count: 4, axis: .horizontal, axes: axes) == 0)
        #expect(Dwindle.split(beside: 0, count: 4, axis: .vertical, axes: axes) == nil)
        // Window 1 owns split 1 (stacked); horizontally its divider is split 0.
        #expect(Dwindle.split(beside: 1, count: 4, axis: .vertical, axes: axes) == 1)
        #expect(Dwindle.split(beside: 1, count: 4, axis: .horizontal, axes: axes) == 0)
        // The last window owns no split; it uses the nearest enclosing one per axis.
        #expect(Dwindle.split(beside: 3, count: 4, axis: .horizontal, axes: axes) == 2)
        #expect(Dwindle.split(beside: 3, count: 4, axis: .vertical, axes: axes) == 1)
    }

    @Test func framesNeverOverlap() {
        let frames = Dwindle.layout(count: 8, in: screen, gapsIn: 2, gapsOut: 2)
        for i in frames.indices {
            for j in frames.indices where i < j {
                #expect(!frames[i].intersects(frames[j]))
            }
        }
    }
}

@Suite struct DominoTests {
    @Test(arguments: 1...9) func pipCountMatchesValue(_ n: Int) {
        let pips = Domino.pips(for: n)
        #expect(pips.count == n)
        #expect(Set(pips).count == n)
        #expect(pips.allSatisfy { (0...2).contains($0.column) && (0...2).contains($0.row) })
    }
}

@Suite struct BorderGeometryTests {
    // AX coordinates: y grows down, so the screen's bottom edge is maxY.
    let screen = CGRect(x: 0, y: 0, width: 1000, height: 600)

    @Test func windowAwayFromCornersHugsWindowRadius() {
        let r = BorderGeometry.outerRadii(windowFrame: CGRect(x: 100, y: 100, width: 300, height: 300), screenFrame: screen,
                                          windowRadius: 14, borderWidth: 2, displayRadius: 31, proximity: 8)
        #expect(r == CornerRadii(uniform: 16))
    }

    @Test func bottomCornersFollowDisplayConcentrically() {
        // Full-screen tile with a 6pt outer gap: the border's outer edge is 4pt from each edge.
        let r = BorderGeometry.outerRadii(windowFrame: screen.insetBy(dx: 6, dy: 6), screenFrame: screen,
                                          windowRadius: 14, borderWidth: 2, displayRadius: 31, proximity: 8)
        #expect(r == CornerRadii(topLeft: 16, topRight: 16, bottomLeft: 27, bottomRight: 27))
    }

    @Test func onlyTheCornerInTheDisplayCornerChanges() {
        // Left half of the screen: bottom-left is in the corner, bottom-right isn't.
        let r = BorderGeometry.outerRadii(windowFrame: CGRect(x: 6, y: 6, width: 491, height: 588), screenFrame: screen,
                                          windowRadius: 14, borderWidth: 2, displayRadius: 31, proximity: 8)
        #expect(r == CornerRadii(topLeft: 16, topRight: 16, bottomLeft: 27, bottomRight: 16))
    }

    @Test func disabledOrSquareDisplayKeepsWindowRadius() {
        let frame = screen.insetBy(dx: 6, dy: 6)
        let off = BorderGeometry.outerRadii(windowFrame: frame, screenFrame: screen, windowRadius: 14,
                                            borderWidth: 2, displayRadius: nil, proximity: 8)
        #expect(off == CornerRadii(uniform: 16))
    }
}

@Suite struct DragDropTests {
    let tiles: [Int: CGRect] = [
        1: CGRect(x: 0, y: 0, width: 500, height: 600),
        2: CGRect(x: 500, y: 0, width: 500, height: 300),
        3: CGRect(x: 500, y: 300, width: 500, height: 300),
    ]
    let tileSize = CGSize(width: 500, height: 600)

    @Test func droppingOnAnotherTileSwaps() {
        #expect(DragDrop.swapTarget(dragged: 1, currentSize: tileSize, cursor: CGPoint(x: 700, y: 450), tiles: tiles) == 3)
    }

    @Test func droppingOnOwnTileSnapsBack() {
        #expect(DragDrop.swapTarget(dragged: 1, currentSize: tileSize, cursor: CGPoint(x: 100, y: 100), tiles: tiles) == nil)
    }

    @Test func resizingNeverSwaps() {
        let resized = CGSize(width: 650, height: 600)
        #expect(DragDrop.swapTarget(dragged: 1, currentSize: resized, cursor: CGPoint(x: 700, y: 450), tiles: tiles) == nil)
    }
}

@Suite struct DisplayAssignmentTests {
    @Test func externalDisplaysComeFirst() {
        #expect(DisplayAssignment.order(builtIn: [true, false]) == [1, 0])
        #expect(DisplayAssignment.order(builtIn: [false, true]) == [0, 1])
        #expect(DisplayAssignment.order(builtIn: [true]) == [0])
        #expect(DisplayAssignment.order(builtIn: [false, true, false]) == [0, 2, 1])
    }

    @Test func oddOnPrimaryEvenOnSecondary() {
        #expect((1...9).map { DisplayAssignment.display(for: $0, displayCount: 2) } == [0, 1, 0, 1, 0, 1, 0, 1, 0])
        #expect((1...9).allSatisfy { DisplayAssignment.display(for: $0, displayCount: 1) == 0 })
    }

    @Test func visibleWorkspacesPerDisplay() {
        // Connecting a second display: the primary keeps 3, the secondary shows 2.
        #expect(DisplayAssignment.visible(previous: [0: 3], displayCount: 2, workspaceCount: 9) == [0: 3, 1: 2])
        // Disconnecting: an even workspace can't stay on the only display.
        #expect(DisplayAssignment.visible(previous: [0: 4, 1: 6], displayCount: 1, workspaceCount: 9) == [0: 4])
        #expect(DisplayAssignment.visible(previous: [0: 3, 1: 6], displayCount: 1, workspaceCount: 9) == [0: 3])
        // Fewer workspaces than displays.
        #expect(DisplayAssignment.visible(previous: [:], displayCount: 2, workspaceCount: 1) == [0: 1])
    }

    // Primary 1000×600 at the origin; secondary 800×600 to its right.
    let primary = CGRect(x: 0, y: 0, width: 1000, height: 600)
    let rightOf = CGRect(x: 1000, y: 0, width: 800, height: 600)
    let size = CGSize(width: 400, height: 300)

    @Test func parksAwayFromNeighbouringDisplay() {
        // Bottom-right of the primary would spill onto the secondary, so use bottom-left.
        #expect(DisplayAssignment.parkingOrigin(display: primary, allDisplays: [primary, rightOf], windowSize: size)
                == CGPoint(x: -399, y: 599))
        // The secondary has nothing to its right, so bottom-right is fine.
        #expect(DisplayAssignment.parkingOrigin(display: rightOf, allDisplays: [primary, rightOf], windowSize: size)
                == CGPoint(x: 1799, y: 599))
        // Single display: bottom-right, as before.
        #expect(DisplayAssignment.parkingOrigin(display: primary, allDisplays: [primary], windowSize: size)
                == CGPoint(x: 999, y: 599))
    }
}
