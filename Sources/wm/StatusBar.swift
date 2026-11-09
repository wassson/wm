import AppKit
import WMCore

/// Menu bar items: one domino per display showing that display's workspace, ordered left
/// to right like the displays. With more than one display, the focused display's domino
/// is drawn filled.
@MainActor
final class StatusBarController: NSObject {
    private struct Item {
        let statusItem: NSStatusItem
        let header: NSMenuItem
        let error: NSMenuItem
    }

    private var items: [Item] = []
    private var errorMessage: String?
    private var lastStatus: WorkspaceStatus?
    private let onReload: () -> Void

    init(onReload: @escaping () -> Void) {
        self.onReload = onReload
        super.init()
    }

    func update(_ status: WorkspaceStatus) {
        guard status != lastStatus else { return }
        lastStatus = status
        let displays = status.displays.isEmpty ? [DisplayStatus(name: "", workspace: status.active)] : status.displays
        if items.count != displays.count { rebuild(count: displays.count) }

        let multiple = displays.count > 1
        let others = status.occupied.subtracting(displays.map(\.workspace)).sorted().map(String.init)
        for (item, display) in zip(items, displays) {
            let focused = multiple && display.workspace == status.active
            let button = item.statusItem.button
            button?.image = DominoIcon.image(for: display.workspace, filled: focused)
            var label = "Workspace \(display.workspace)"
            if multiple && !display.name.isEmpty { label = "\(display.name): \(label)" }
            button?.setAccessibilityLabel(label)
            var title = label
            if focused { title += " (focused)" }
            if !others.isEmpty { title += "  ·  also in use: \(others.joined(separator: ", "))" }
            item.header.title = title
        }
        applyError()
    }

    func setError(_ message: String?) {
        errorMessage = message
        applyError()
    }

    private func applyError() {
        for item in items {
            item.error.isHidden = errorMessage == nil
            item.error.title = errorMessage.map { "⚠︎ Config error — \($0)" } ?? ""
        }
    }

    /// Recreates every item so they stay in display order: macOS puts each new status
    /// item to the left of the existing ones, so the rightmost display goes first.
    private func rebuild(count: Int) {
        for item in items { NSStatusBar.system.removeStatusItem(item.statusItem) }
        items = (0..<count).reversed().map { _ in makeItem() }.reversed()
    }

    private func makeItem() -> Item {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let header = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        header.isEnabled = false
        let error = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        error.isEnabled = false
        error.isHidden = true

        let menu = NSMenu()
        menu.addItem(header)
        menu.addItem(error)
        menu.addItem(.separator())
        addItem(to: menu, "Reload Config", #selector(reload), "r")
        addItem(to: menu, "Open Config", #selector(openConfig), ",")
        menu.addItem(.separator())
        addItem(to: menu, "Quit wm", #selector(quit), "q")
        statusItem.menu = menu
        return Item(statusItem: statusItem, header: header, error: error)
    }

    private func addItem(to menu: NSMenu, _ title: String, _ action: Selector, _ key: String) {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: key)
        menuItem.target = self
        menu.addItem(menuItem)
    }

    @objc private func reload() { onReload() }
    @objc private func openConfig() { NSWorkspace.shared.open(ConfigStore.url) }
    @objc private func quit() { NSApp.terminate(nil) }
}

@MainActor
enum DominoIcon {
    private static var cache: [Int: NSImage] = [:]

    /// A domino tile with the workspace number shown as pips: an outline normally, or a
    /// solid tile with the pips cut out when `filled`. Template image, so it follows the
    /// menu bar's light/dark appearance.
    static func image(for value: Int, filled: Bool = false) -> NSImage {
        let key = filled ? -value : value
        if let cached = cache[key] { return cached }
        let image = render(value, filled: filled)
        cache[key] = image
        return image
    }

    private static func render(_ value: Int, filled: Bool) -> NSImage {
        let pips = Domino.pips(for: value)
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: true) { rect in
            let tile = rect.insetBy(dx: 0.75, dy: 0.75)
            let outline = NSBezierPath(roundedRect: tile, xRadius: 3.5, yRadius: 3.5)
            NSColor.black.set()
            if filled {
                outline.fill()
                NSGraphicsContext.current?.compositingOperation = .destinationOut
            } else {
                outline.lineWidth = 1.25
                outline.stroke()
            }

            let grid = tile.insetBy(dx: 3.6, dy: 3.6)
            let r: CGFloat = 1.35
            for pip in pips {
                let x = grid.minX + CGFloat(pip.column) * grid.width / 2
                let y = grid.minY + CGFloat(pip.row) * grid.height / 2
                NSBezierPath(ovalIn: NSRect(x: x - r, y: y - r, width: r * 2, height: r * 2)).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Workspace \(value)"
        return image
    }
}
