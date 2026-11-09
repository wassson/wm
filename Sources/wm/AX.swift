import AppKit
import ApplicationServices

/// Private but long-stable API (used by yabai, Amethyst, AeroSpace, Rectangle) that maps
/// an AX window element to its CGWindowID, which gives windows a stable identity.
@_silgen_name("_AXUIElementGetWindow")
@discardableResult
private func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

/// Number of Accessibility round trips to other processes. Each one blocks the main
/// thread until the target app answers, so this is the main cost to keep down.
nonisolated(unsafe) var axCallCount = 0

extension AXUIElement {
    func copy(_ attribute: String) -> CFTypeRef? {
        axCallCount += 1
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    @discardableResult
    func set(_ attribute: String, _ value: CFTypeRef) -> AXError {
        axCallCount += 1
        return AXUIElementSetAttributeValue(self, attribute as CFString, value)
    }

    var windowID: CGWindowID? {
        axCallCount += 1
        var id: CGWindowID = 0
        return _AXUIElementGetWindow(self, &id) == .success && id != 0 ? id : nil
    }

    var pid: pid_t? {
        var pid: pid_t = 0
        return AXUIElementGetPid(self, &pid) == .success ? pid : nil
    }

    var role: String? { copy(kAXRoleAttribute) as? String }
    var subrole: String? { copy(kAXSubroleAttribute) as? String }
    var title: String? { copy(kAXTitleAttribute) as? String }
    var isMinimized: Bool { (copy(kAXMinimizedAttribute) as? Bool) ?? false }
    var isFullscreen: Bool { (copy("AXFullScreen") as? Bool) ?? false }

    var isResizable: Bool {
        axCallCount += 1
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(self, kAXSizeAttribute as CFString, &settable) == .success
            && settable.boolValue
    }

    var windows: [AXUIElement] {
        (copy(kAXWindowsAttribute) as? [AXUIElement]) ?? []
    }

    var focusedWindow: AXUIElement? {
        guard let value = copy(kAXFocusedWindowAttribute),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    /// Fetches several attributes in a single round trip. Attributes the element doesn't
    /// support come back as nil.
    func copyMultiple(_ attributes: [String]) -> [CFTypeRef?]? {
        axCallCount += 1
        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(self, attributes as CFArray, AXCopyMultipleAttributeOptions(), &values) == .success,
              let array = values as? [CFTypeRef], array.count == attributes.count else { return nil }
        return array.map { value in
            // Per-attribute failures are reported as AXValues of type .axError.
            if CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetType(value as! AXValue) == .axError { return nil }
            return value
        }
    }

    /// Frame in Accessibility coordinates (origin at top-left of the primary screen).
    var frame: CGRect? {
        guard let v = copyMultiple([kAXPositionAttribute, kAXSizeAttribute]) else { return nil }
        return Self.rect(position: v[0], size: v[1])
    }

    /// Frame, minimized and fullscreen state in one round trip.
    var state: WindowState? {
        guard let v = copyMultiple([kAXPositionAttribute, kAXSizeAttribute, kAXMinimizedAttribute, "AXFullScreen"]) else {
            return nil
        }
        return WindowState(frame: Self.rect(position: v[0], size: v[1]),
                           isMinimized: (v[2] as? Bool) ?? false,
                           isFullscreen: (v[3] as? Bool) ?? false)
    }

    private static func rect(position: CFTypeRef?, size: CFTypeRef?) -> CGRect? {
        guard let p = position, let s = size,
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &origin),
              AXValueGetValue(s as! AXValue, .cgSize, &extent) else { return nil }
        return CGRect(origin: origin, size: extent)
    }

    func setPosition(_ point: CGPoint) {
        var point = point
        if let value = AXValueCreate(.cgPoint, &point) { set(kAXPositionAttribute, value) }
    }

    func setSize(_ size: CGSize) {
        var size = size
        if let value = AXValueCreate(.cgSize, &size) { set(kAXSizeAttribute, value) }
    }

    /// Size → position → size: the first resize lets a window shrink before moving
    /// somewhere it wouldn't fit; the second fixes sizes the app clamped mid-move.
    func setFrame(_ frame: CGRect) {
        setSize(frame.size)
        setPosition(frame.origin)
        setSize(frame.size)
    }
}

struct WindowState {
    var frame: CGRect?
    var isMinimized: Bool
    var isFullscreen: Bool
}

/// Runs `body` with AXEnhancedUserInterface disabled for the app. Some apps
/// (and VoiceOver-style tooling) enable it, which makes AX frame changes animate slowly.
func withoutEnhancedUI(pid: pid_t, _ body: () -> Void) {
    let app = AXUIElementCreateApplication(pid)
    let enhanced = (app.copy("AXEnhancedUserInterface") as? Bool) ?? false
    if enhanced { app.set("AXEnhancedUserInterface", kCFBooleanFalse) }
    body()
    if enhanced { app.set("AXEnhancedUserInterface", kCFBooleanTrue) }
}

/// Private SkyLight call reporting a display's physical corner radii (points). Each
/// pointer receives one corner; on the PROLED XDR all four are ~31pt. Looked up at
/// runtime so a macOS release without it just falls back to uniform corners.
private typealias DisplayCornerRadiiFn = @convention(c) (
    CGDirectDisplayID, UnsafeMutablePointer<Double>?, UnsafeMutablePointer<Double>?,
    UnsafeMutablePointer<Double>?, UnsafeMutablePointer<Double>?
) -> CGError

private let SLSDisplayGetCornerRadii: DisplayCornerRadiiFn? = {
    guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
          let symbol = dlsym(handle, "SLSDisplayGetCornerRadii") else { return nil }
    return unsafeBitCast(symbol, to: DisplayCornerRadiiFn.self)
}()

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// The display's rounded-corner radius, or nil for square displays.
    /// The per-corner values differ by hundredths of a point, so the largest is used.
    var cornerRadius: Double? {
        guard let id = displayID else { return nil }
        var a = 0.0, b = 0.0, c = 0.0, d = 0.0
        guard let getRadii = SLSDisplayGetCornerRadii, getRadii(id, &a, &b, &c, &d) == .success else { return nil }
        let r = max(a, b, c, d)
        return r > 0 ? r : nil
    }
}

/// Converts between AppKit screen coordinates (origin bottom-left of the primary
/// screen) and Accessibility coordinates (origin top-left of the primary screen).
/// The conversion is its own inverse.
enum Geometry {
    static var primaryScreen: NSScreen? { NSScreen.screens.first }

    static func flip(_ rect: CGRect) -> CGRect {
        let height = primaryScreen?.frame.height ?? 0
        return CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
    }

    private static var cachedAreas: [CGDirectDisplayID: (rect: CGRect, at: TimeInterval)] = [:]

    /// The tiling area (excludes menu bar and Dock) in AX coordinates.
    /// `visibleFrame` costs ~150µs per call, so it's cached for a second; a display
    /// change clears the cache immediately (see `invalidateTilingArea`).
    @MainActor
    static func tilingArea(of screen: NSScreen) -> CGRect {
        let now = ProcessInfo.processInfo.systemUptime
        let key = screen.displayID ?? 0
        if let c = cachedAreas[key], now - c.at < 1 { return c.rect }
        let rect = flip(screen.visibleFrame)
        cachedAreas[key] = (rect, now)
        return rect
    }

    @MainActor
    static func invalidateTilingArea() { cachedAreas.removeAll() }
    static func fullFrame(of screen: NSScreen) -> CGRect { flip(screen.frame) }
}

extension CGRect {
    func isClose(to other: CGRect, tolerance: CGFloat = 1) -> Bool {
        abs(minX - other.minX) <= tolerance && abs(minY - other.minY) <= tolerance
            && abs(width - other.width) <= tolerance && abs(height - other.height) <= tolerance
    }

    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
