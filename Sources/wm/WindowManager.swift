import AppKit
import ApplicationServices
import WMCore

@MainActor
final class ManagedWindow {
    let id: CGWindowID
    let element: AXUIElement
    let pid: pid_t
    let bundleID: String?
    let appName: String?
    var workspace: Int
    var isFloating: Bool
    /// True while parked off-screen because its workspace isn't active.
    var isHidden = false
    /// Last on-screen frame of a floating window, restored when its workspace is shown.
    var floatingFrame: CGRect?

    init(id: CGWindowID, element: AXUIElement, pid: pid_t, bundleID: String?, appName: String?, workspace: Int, isFloating: Bool) {
        self.appName = appName
        self.id = id
        self.element = element
        self.pid = pid
        self.bundleID = bundleID
        self.workspace = workspace
        self.isFloating = isFloating
    }
}

private let appNotifications = [
    kAXWindowCreatedNotification,
    kAXFocusedWindowChangedNotification,
]

private let windowNotifications = [
    kAXUIElementDestroyedNotification,
    kAXMovedNotification,
    kAXResizedNotification,
    kAXWindowMiniaturizedNotification,
    kAXWindowDeminiaturizedNotification,
]

private let axCallback: AXObserverCallback = { _, element, notification, refcon in
    guard let refcon else { return }
    let wm = Unmanaged<WindowManager>.fromOpaque(refcon).takeUnretainedValue()
    let name = notification as String
    MainActor.assumeIsolated { wm.handle(name, element: element) }
}

/// Tracks windows via the Accessibility API, assigns them to workspaces, tiles the
/// active workspace with the dwindle layout and draws the focus border.
///
/// macOS has no public API for creating Spaces, so (like AeroSpace) inactive
/// workspaces are emulated by parking their windows just off a corner of their display.
///
/// Each display shows one workspace at a time (odd workspaces on an external display,
/// even ones on a second display). `activeWorkspace` is the visible one with focus.
struct DisplayStatus: Equatable {
    let name: String
    let workspace: Int
}

struct WorkspaceStatus: Equatable {
    /// The visible workspace with focus.
    let active: Int
    /// One entry per display showing a workspace, ordered left to right.
    let displays: [DisplayStatus]
    let occupied: Set<Int>
}

@MainActor
final class WindowManager {
    private(set) var config: Config
    private(set) var activeWorkspace = 1
    /// The workspace each display is showing, keyed by display index (see `DisplayAssignment.order`).
    private var visible: [Int: Int] = [0: 1]
    /// Displays in index order, as of the last display change.
    private var screens: [NSScreen] = []

    /// Called whenever the focused workspace, a display's workspace, or the set of
    /// occupied workspaces may have changed.
    var onWorkspaceChange: ((WorkspaceStatus) -> Void)?

    private var windows: [CGWindowID: ManagedWindow] = [:]
    /// Tiling order per workspace.
    private var order: [Int: [CGWindowID]] = [:]
    private var lastFocused: [Int: CGWindowID] = [:]
    private var observers: [pid_t: AXObserver] = [:]
    private let border = BorderWindow()

    /// Focus changes during a workspace switch shouldn't trigger "follow focus".
    private var suppressFollowUntil = Date.distantPast
    /// Move/resize events caused by our own layout shouldn't trigger a snap-back.
    private var ignoreMovesUntil = Date.distantPast
    private var snapBackTask: Task<Void, Never>?
    /// Each tiled window's assigned frame on the visible workspaces (AX coordinates).
    private var tileFrames: [CGWindowID: CGRect] = [:]
    /// Tiled windows of each visible workspace in layout order, as of the last layout.
    private var tiledOrder: [Int: [CGWindowID]] = [:]
    /// Split ratios per workspace, by split index (window i's share of split i).
    private var ratios: [Int: [Int: Double]] = [:]
    /// The tiled window the user is currently dragging, if any.
    private var draggedWindow: CGWindowID?
    /// The focused window as of the last focus notification, so frequent border updates
    /// don't have to ask the frontmost app every time.
    private var focusedID: CGWindowID?
    /// Each display's corner radius (nil for square displays), by display index.
    private var displayCornerRadii: [Int: Double] = [:]

    private var refcon: UnsafeMutableRawPointer { Unmanaged.passUnretained(self).toOpaque() }

    init(config: Config) {
        self.config = config
    }

    // MARK: - Lifecycle

    func start() {
        // Window elements otherwise use macOS's 6-second default, so a single hung app
        // could freeze window management for seconds at a time.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.5)

        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated { self?.observe(app) }
        }
        center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            MainActor.assumeIsolated { self?.removeApp(pid) }
        }
        center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated {
                self?.rescan(app)
                self?.focusDidChange(followAcrossWorkspaces: true)
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.displaysDidChange() }
        }

        refreshDisplays()
        for app in NSWorkspace.shared.runningApplications { observe(app) }
        layout()
        focusDidChange(followAcrossWorkspaces: false)
        notifyWorkspaceChange()
    }

    /// Brings every parked window back on screen. Called on quit so nothing is left stranded.
    func revealAll() {
        for w in windows.values where w.isHidden {
            guard let screen = screen(for: w.workspace) else { continue }
            let area = Geometry.tilingArea(of: screen)
            if let frame = w.floatingFrame {
                w.element.setFrame(frame)
            } else if let frame = w.element.frame {
                w.element.setPosition(CGPoint(x: area.midX - frame.width / 2, y: area.midY - frame.height / 2))
            }
            w.isHidden = false
        }
        border.orderOut(nil)
    }

    func apply(config newConfig: Config) {
        config = newConfig
        let count = newConfig.workspaceCount

        // Fold windows from workspaces that no longer exist into the last one.
        for ws in order.keys.sorted() where ws > count {
            for id in order[ws] ?? [] {
                windows[id]?.workspace = count
                order[count, default: []].append(id)
            }
            order[ws] = nil
            lastFocused[ws] = nil
        }
        visible = DisplayAssignment.visible(previous: visible, displayCount: screens.count, workspaceCount: count)
        if !isVisible(activeWorkspace) { activeWorkspace = visible[0] ?? 1 }

        syncVisibility()
        notifyWorkspaceChange()
    }

    // MARK: - Displays

    private func refreshDisplays() {
        // External displays take the odd workspaces, the built-in display the even ones.
        let all = NSScreen.screens
        let builtIn: [Bool] = all.map { screen in
            guard let id = screen.displayID else { return false }
            return CGDisplayIsBuiltin(id) != 0
        }
        screens = DisplayAssignment.order(builtIn: builtIn).map { all[$0] }
        Geometry.invalidateTilingArea()
        displayCornerRadii = [:]
        for (i, screen) in screens.enumerated() {
            if let r = screen.cornerRadius { displayCornerRadii[i] = r }
        }
        visible = DisplayAssignment.visible(previous: visible, displayCount: screens.count,
                                            workspaceCount: config.workspaceCount)
        if !isVisible(activeWorkspace) { activeWorkspace = visible[0] ?? 1 }
    }

    /// A display was connected, disconnected or rearranged.
    private func displaysDidChange() {
        refreshDisplays()
        // Parking spots depend on the arrangement; macOS also drags windows off a
        // disconnected display. Re-park every hidden window for the new layout.
        for w in windows.values where w.isHidden { hide(w) }
        syncVisibility()
        notifyWorkspaceChange()
    }

    private func isVisible(_ workspace: Int) -> Bool { visible.values.contains(workspace) }

    private func displayIndex(for workspace: Int) -> Int {
        DisplayAssignment.display(for: workspace, displayCount: screens.count)
    }

    private func screen(for workspace: Int) -> NSScreen? {
        let index = displayIndex(for: workspace)
        return index < screens.count ? screens[index] : Geometry.primaryScreen
    }

    // MARK: - Commands

    func switchToWorkspace(_ n: Int) {
        guard (1...config.workspaceCount).contains(n), n != activeWorkspace else { return }
        if let focused = focusedManagedWindow(), isVisible(focused.workspace) {
            lastFocused[focused.workspace] = focused.id
        }
        suppressFollowUntil = Date().addingTimeInterval(0.6)
        // Only the workspace's own display changes; the other display keeps what it shows.
        visible[displayIndex(for: n)] = n
        activeWorkspace = n
        syncVisibility()

        let ids = order[n] ?? []
        if let target = lastFocused[n].flatMap({ windows[$0] }) ?? ids.first.flatMap({ windows[$0] }) {
            focus(target)
        } else {
            border.orderOut(nil)
        }
        notifyWorkspaceChange()
    }

    func moveFocusedWindow(toWorkspace n: Int) {
        guard (1...config.workspaceCount).contains(n), let w = focusedManagedWindow(),
              isVisible(w.workspace), w.workspace != n else { return }
        let from = w.workspace

        suppressFollowUntil = Date().addingTimeInterval(0.6)
        order[from]?.removeAll { $0 == w.id }
        order[n, default: []].append(w.id)
        w.workspace = n
        lastFocused[n] = w.id
        if lastFocused[from] == w.id { lastFocused[from] = nil }
        // A workspace showing on the other display takes the window straight away.
        if !isVisible(n) { hide(w) }
        activeWorkspace = from
        layout()

        if let next = (order[activeWorkspace] ?? []).lazy.compactMap({ self.windows[$0] }).first {
            focus(next)
        } else {
            border.orderOut(nil)
        }
        notifyWorkspaceChange()
    }

    /// Moves focus to the nearest window in that direction, across displays.
    func focus(_ direction: Direction) {
        let candidates = visibleWindows()
        guard let current = focusedManagedWindow(), isVisible(current.workspace) else {
            if let first = candidates.first { focus(first) }
            return
        }
        if let target = neighbor(of: current, direction, among: candidates) { focus(target) }
    }

    func swap(_ direction: Direction) {
        guard let current = focusedManagedWindow(), isVisible(current.workspace), !current.isFloating,
              let target = neighbor(of: current, direction, among: visibleWindows().filter {
                  !$0.isFloating && $0.workspace == current.workspace
              }),
              var ids = order[current.workspace],
              let a = ids.firstIndex(of: current.id), let b = ids.firstIndex(of: target.id) else { return }
        ids.swapAt(a, b)
        order[current.workspace] = ids
        layout()
    }

    /// Moves the divider beside the focused tiled window left/right/up/down. The windows
    /// on either side of it grow and shrink to match.
    func moveSplit(_ direction: Direction) {
        guard let w = focusedManagedWindow(), isVisible(w.workspace), !w.isFloating,
              let screen = screen(for: w.workspace),
              let tiled = tiledOrder[w.workspace], let index = tiled.firstIndex(of: w.id) else { return }
        let axis: Dwindle.Axis = (direction == .left || direction == .right) ? .horizontal : .vertical
        let axes = Dwindle.axes(count: tiled.count, in: Geometry.tilingArea(of: screen),
                                gapsIn: config.gapsIn, gapsOut: config.gapsOut)
        guard let split = Dwindle.split(beside: index, count: tiled.count, axis: axis, axes: axes) else {
            return  // no divider beside it on that axis (e.g. a single window)
        }
        // A split's ratio is the share of its first (left/top) part, so moving the
        // divider right or down raises it.
        let delta = (direction == .right || direction == .down) ? config.resizeStep : -config.resizeStep
        var splits = ratios[w.workspace] ?? [:]
        splits[split] = Dwindle.clamp((splits[split] ?? 0.5) + delta)
        ratios[w.workspace] = splits
        layout()
    }

    func toggleFloat() {
        guard let w = focusedManagedWindow(), isVisible(w.workspace),
              let screen = screen(for: w.workspace) else { return }
        w.isFloating.toggle()
        if w.isFloating {
            let area = Geometry.tilingArea(of: screen)
            let size = CGSize(width: (area.width * 0.6).rounded(), height: (area.height * 0.6).rounded())
            let frame = CGRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2,
                               width: size.width, height: size.height)
            ignoreMovesUntil = Date().addingTimeInterval(0.3)
            withoutEnhancedUI(pid: w.pid) { w.element.setFrame(frame) }
            w.element.performRaise()
        }
        layout()
    }

    // MARK: - Accessibility events

    fileprivate func handle(_ notification: String, element: AXUIElement) {
        switch notification {
        case kAXWindowCreatedNotification:
            guard let pid = element.pid else { return }
            if track(element, pid: pid) {
                layout()
                notifyWorkspaceChange()
            }
        case kAXUIElementDestroyedNotification:
            // The element is already dead, so its window ID can't be queried; match by identity.
            if let w = windows.values.first(where: { CFEqual($0.element, element) }) {
                untrack(w.id)
                layout()
                focusDidChange(followAcrossWorkspaces: false)
                notifyWorkspaceChange()
            }
        case kAXFocusedWindowChangedNotification:
            focusDidChange(followAcrossWorkspaces: true)
        case kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification:
            layout()
        case kAXMovedNotification, kAXResizedNotification:
            // Matching by element identity is local; asking for the window ID is a round trip.
            let moved = windows.values.first { CFEqual($0.element, element) }
            if let moved, moved.id == focusedID { updateBorder(for: moved) }
            if Date() >= ignoreMovesUntil, let moved, tileFrames[moved.id] != nil {
                draggedWindow = moved.id
            }
            scheduleSnapBack()
        default:
            break
        }
    }

    private func observe(_ app: NSRunningApplication, attempt: Int = 0) {
        let pid = app.processIdentifier
        guard pid != getpid(), observers[pid] == nil, !app.isTerminated else { return }

        // Apps that are still launching may not have set their activation policy yet,
        // and reject AX observers until they're ready; retry for a few seconds.
        func retry() {
            guard attempt < 10 else { return }
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                self?.observe(app, attempt: attempt + 1)
            }
        }
        guard app.activationPolicy == .regular else {
            if !app.isFinishedLaunching { retry() }
            return
        }

        let appElement = AXUIElementCreateApplication(pid)

        var created: AXObserver?
        guard AXObserverCreate(pid, axCallback, &created) == .success, let observer = created else { return }
        guard AXObserverAddNotification(observer, appElement, kAXWindowCreatedNotification as CFString, refcon) == .success else {
            retry()
            return
        }
        for name in appNotifications.dropFirst() {
            AXObserverAddNotification(observer, appElement, name as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        observers[pid] = observer

        var added = false
        for element in appElement.windows where track(element, pid: pid) { added = true }
        if added {
            layout()
            notifyWorkspaceChange()
        }
    }

    /// Adds a window to the active workspace. Returns false if it isn't a manageable window.
    @discardableResult
    private func track(_ element: AXUIElement, pid: pid_t) -> Bool {
        guard element.role == kAXWindowRole,
              element.subrole == kAXStandardWindowSubrole,
              let id = element.windowID,
              windows[id] == nil,
              let observer = observers[pid] else { return false }

        let app = NSRunningApplication(processIdentifier: pid)
        let bundleID = app?.bundleIdentifier
        let floating = bundleID.map { config.floatingApps.contains($0) } ?? false || !element.isResizable
        // A new window joins the workspace showing on the display it opened on.
        var workspace = activeWorkspace
        if let center = element.frame?.center,
           let d = DisplayAssignment.display(containing: center, displays: screens.map(Geometry.fullFrame)),
           let ws = visible[d] {
            workspace = ws
        }
        let window = ManagedWindow(id: id, element: element, pid: pid, bundleID: bundleID, appName: app?.localizedName,
                                   workspace: workspace, isFloating: floating)
        windows[id] = window
        order[workspace, default: []].append(id)
        for name in windowNotifications {
            AXObserverAddNotification(observer, element, name as CFString, refcon)
        }
        return true
    }

    private func untrack(_ id: CGWindowID) {
        guard let w = windows.removeValue(forKey: id) else { return }
        order[w.workspace]?.removeAll { $0 == id }
        if lastFocused[w.workspace] == id { lastFocused[w.workspace] = nil }
    }

    private func removeApp(_ pid: pid_t) {
        observers[pid] = nil
        let ids = windows.values.filter { $0.pid == pid }.map(\.id)
        guard !ids.isEmpty else { return }
        ids.forEach(untrack)
        layout()
        notifyWorkspaceChange()
    }

    /// Picks up windows whose creation we missed and drops ones that vanished.
    private func rescan(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard observers[pid] != nil else { observe(app); return }
        let elements = AXUIElementCreateApplication(pid).windows
        let live = Set(elements.compactMap(\.windowID))

        var changed = false
        for w in windows.values where w.pid == pid && !live.contains(w.id) {
            untrack(w.id)
            changed = true
        }
        for element in elements where track(element, pid: pid) { changed = true }
        if changed {
            layout()
            notifyWorkspaceChange()
        }
    }

    // MARK: - Layout & visibility

    /// Tiles every visible workspace on its display.
    func layout() {
        ignoreMovesUntil = Date().addingTimeInterval(0.3)
        tileFrames = [:]
        tiledOrder = [:]
        for (_, ws) in visible.sorted(by: { $0.key < $1.key }) {
            layout(workspace: ws)
        }
        updateBorder()
    }

    private func layout(workspace ws: Int) {
        guard let screen = screen(for: ws) else { return }
        // One round trip per window for frame + minimized + fullscreen.
        let tiled = (order[ws] ?? [])
            .compactMap { windows[$0] }
            .filter { !$0.isFloating }
            .map { ($0, $0.element.state) }
            .filter { _, state in !(state?.isMinimized ?? false) && !(state?.isFullscreen ?? false) }
        let splits = ratios[ws] ?? [:]
        let frames = Dwindle.layout(count: tiled.count, in: Geometry.tilingArea(of: screen),
                                    gapsIn: config.gapsIn, gapsOut: config.gapsOut,
                                    ratios: (0..<max(tiled.count - 1, 0)).map { splits[$0] ?? 0.5 })
        tiledOrder[ws] = tiled.map(\.0.id)
        let display = Geometry.fullFrame(of: screen)
        var crossed: [ManagedWindow] = []
        for ((w, state), frame) in zip(tiled, frames) {
            tileFrames[w.id] = frame
            w.isHidden = false
            if let current = state?.frame, current.isClose(to: frame) { continue }
            withoutEnhancedUI(pid: w.pid) { w.element.setFrame(frame) }
            if let current = state?.frame, !display.contains(CGPoint(x: current.midX, y: current.midY)) {
                crossed.append(w)
            }
        }
        if !crossed.isEmpty { recheckFrames(of: crossed) }
    }

    /// Windows moved onto another display get resized while macOS still thinks they're on
    /// the old one, so apps cap them to that display's size (a MacBook-height window on a
    /// Studio Display). Once the move has settled, put back any frame that came out wrong.
    private func recheckFrames(of moved: [ManagedWindow]) {
        Task { @MainActor [weak self] in
            var fixed = false
            for delay in [80, 250] {
                try? await Task.sleep(for: .milliseconds(delay))
                guard let self else { return }
                var pending = false
                for w in moved where self.windows[w.id] === w && !w.isHidden && !w.isFloating {
                    guard let target = self.tileFrames[w.id], let current = w.element.frame,
                          !current.isClose(to: target) else { continue }
                    self.ignoreMovesUntil = Date().addingTimeInterval(0.5)
                    withoutEnhancedUI(pid: w.pid) { w.element.setFrame(target) }
                    pending = true
                    fixed = true
                }
                if !pending { break }
            }
            if fixed { self?.updateBorder() }
        }
    }

    /// Parks windows of hidden workspaces, restores the visible workspaces' windows, then tiles.
    private func syncVisibility() {
        ignoreMovesUntil = Date().addingTimeInterval(0.5)
        for w in windows.values {
            if isVisible(w.workspace) {
                if w.isHidden { unhide(w) }
            } else if !w.isHidden {
                hide(w)
            }
        }
        layout()
    }

    private func hide(_ w: ManagedWindow) {
        guard let screen = screen(for: w.workspace) else { return }
        let frame = w.element.frame
        if w.isFloating, !w.isHidden { w.floatingFrame = frame }
        ignoreMovesUntil = Date().addingTimeInterval(0.5)
        // Just off a corner of its own display, on a side away from any other display.
        let origin = DisplayAssignment.parkingOrigin(display: Geometry.fullFrame(of: screen),
                                                     allDisplays: screens.map(Geometry.fullFrame),
                                                     windowSize: frame?.size ?? .zero)
        w.element.setPosition(origin)
        w.isHidden = true
    }

    private func unhide(_ w: ManagedWindow) {
        if w.isFloating, let frame = w.floatingFrame {
            w.element.setFrame(frame)
        }
        // Tiled windows are positioned by the layout pass that follows.
        w.isHidden = false
    }

    /// When the user drags or resizes a tiled window, wait for the mouse to be released.
    /// Dropping a dragged window onto another tile swaps the two; anything else snaps back.
    private func scheduleSnapBack() {
        guard Date() >= ignoreMovesUntil else { return }
        snapBackTask?.cancel()
        snapBackTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self else { return }
            if NSEvent.pressedMouseButtons != 0 {
                self.ignoreMovesUntil = .distantPast
                self.scheduleSnapBack()
            } else {
                self.finishDrag()
            }
        }
    }

    private func finishDrag() {
        defer {
            draggedWindow = nil
            layout()
        }
        guard let id = draggedWindow, let w = windows[id], isVisible(w.workspace),
              let size = w.element.frame?.size else { return }
        let mouse = NSEvent.mouseLocation  // AppKit coordinates
        let cursor = Geometry.flip(CGRect(origin: mouse, size: .zero)).origin
        let sameWorkspace = Set(tiledOrder[w.workspace] ?? [])
        guard let target = DragDrop.swapTarget(dragged: id, currentSize: size, cursor: cursor,
                                               tiles: tileFrames.filter { sameWorkspace.contains($0.key) }),
              var ids = order[w.workspace],
              let a = ids.firstIndex(of: id), let b = ids.firstIndex(of: target) else { return }
        ids.swapAt(a, b)
        order[w.workspace] = ids
    }

    // MARK: - Focus

    /// Asks the frontmost app for its focused window (2 round trips) and refreshes the cache.
    private func focusedManagedWindow() -> ManagedWindow? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let element = AXUIElementCreateApplication(app.processIdentifier).focusedWindow,
              let id = element.windowID else {
            focusedID = nil
            return nil
        }
        focusedID = windows[id] == nil ? nil : id
        return windows[id]
    }

    private var cachedFocusedWindow: ManagedWindow? { focusedID.flatMap { windows[$0] } }

    private func focus(_ w: ManagedWindow) {
        let app = AXUIElementCreateApplication(w.pid)
        app.set(kAXFrontmostAttribute, kCFBooleanTrue)
        w.element.set(kAXMainAttribute, kCFBooleanTrue)
        w.element.performRaise()
        _ = NSRunningApplication(processIdentifier: w.pid)?.activate(options: [])
        lastFocused[w.workspace] = w.id
        if isVisible(w.workspace), w.workspace != activeWorkspace {
            activeWorkspace = w.workspace
            notifyWorkspaceChange()
        }
        updateBorder(for: w)
    }

    private func focusDidChange(followAcrossWorkspaces: Bool) {
        guard let w = focusedManagedWindow() else {
            border.orderOut(nil)
            return
        }
        if !isVisible(w.workspace) {
            // Like Hyprland: activating a window elsewhere (Cmd-Tab, Dock) jumps to its workspace.
            // Finder is excluded because clicking the desktop activates it.
            if followAcrossWorkspaces, Date() >= suppressFollowUntil, w.bundleID != "com.apple.finder" {
                lastFocused[w.workspace] = w.id
                switchToWorkspace(w.workspace)
            }
            return
        }
        // Focus moved to the other display's workspace (click, Cmd-Tab, focus left/right).
        if w.workspace != activeWorkspace {
            activeWorkspace = w.workspace
            notifyWorkspaceChange()
        }
        lastFocused[activeWorkspace] = w.id
        updateBorder(for: w)
    }

    private func updateBorder(for target: ManagedWindow? = nil) {
        guard config.borderEnabled, config.borderWidth > 0,
              let w = target ?? cachedFocusedWindow,
              isVisible(w.workspace), !w.isHidden,
              let state = w.element.state, !state.isFullscreen,
              let frame = state.frame else {
            border.orderOut(nil)
            return
        }
        let screen = screen(for: w.workspace)
        let radii = BorderGeometry.outerRadii(
            windowFrame: frame,
            screenFrame: screen.map(Geometry.fullFrame) ?? .null,
            windowRadius: config.borderRadius(bundleID: w.bundleID, appName: w.appName),
            borderWidth: config.borderWidth,
            displayRadius: config.matchDisplayCorners ? displayCornerRadii[displayIndex(for: w.workspace)] : nil,
            proximity: max(config.gapsOut.bottom, config.gapsOut.left, config.gapsOut.right) + 2
        )
        border.show(around: Geometry.flip(frame), width: config.borderWidth,
                    radii: radii, color: config.activeBorderColor)
    }

    /// Windows on every display's visible workspace.
    private func visibleWindows() -> [ManagedWindow] {
        visible.sorted(by: { $0.key < $1.key })
            .flatMap { order[$0.value] ?? [] }
            .compactMap { windows[$0] }
            .filter { !$0.element.isMinimized }
    }

    /// The nearest window whose center lies in `direction` from `current`'s center.
    private func neighbor(of current: ManagedWindow, _ direction: Direction, among candidates: [ManagedWindow]) -> ManagedWindow? {
        guard let origin = current.element.frame?.center else { return nil }
        var best: (ManagedWindow, CGFloat)?
        for w in candidates where w.id != current.id {
            guard let c = w.element.frame?.center else { continue }
            let dx = c.x - origin.x
            let dy = c.y - origin.y
            let along: CGFloat
            let across: CGFloat
            switch direction {
            case .left: along = -dx; across = dy
            case .right: along = dx; across = dy
            case .up: along = -dy; across = dx
            case .down: along = dy; across = dx
            }
            guard along > 1 else { continue }
            let score = along + abs(across) * 2
            if best == nil || score < best!.1 { best = (w, score) }
        }
        return best?.0
    }

    private func notifyWorkspaceChange() {
        let occupied = Set(order.filter { !$0.value.isEmpty }.keys)
        // Left to right as the displays are arranged, so the menu bar icons read the same way.
        let displays = screens.indices
            .compactMap { i in visible[i].map { (i, $0) } }
            .sorted { screens[$0.0].frame.minX < screens[$1.0].frame.minX }
            .map { DisplayStatus(name: screens[$0.0].localizedName, workspace: $0.1) }
        onWorkspaceChange?(WorkspaceStatus(active: activeWorkspace, displays: displays, occupied: occupied))
    }
}

// MARK: - Profiling

extension WindowManager {
    /// Times the hot paths without moving anything (layout runs on an already-tiled
    /// workspace). Trigger with `kill -USR1 <pid>`; results go to stderr and the log.
    func runBenchmark() {
        func measure(_ name: String, _ iterations: Int, _ body: () -> Void) {
            let calls = axCallCount
            let start = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<iterations { body() }
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1000 / Double(iterations)
            let perOp = Double(axCallCount - calls) / Double(iterations)
            log(String(format: "bench %-22@ %8.1f µs/op  %5.1f AX calls/op", name as NSString, elapsed, perOp))
        }
        let active = (order[activeWorkspace] ?? []).compactMap { windows[$0] }
        log("bench: \(windows.count) windows tracked, \(active.count) on workspace \(activeWorkspace), \(observers.count) apps observed")
        measure("focusedManagedWindow", 100) { _ = focusedManagedWindow() }
        measure("window state (batched)", 100) { _ = active.first?.element.state }
        measure("updateBorder", 100) { updateBorder() }
        if let frame = active.first?.element.frame {
            measure("  border.show (unchanged)", 100) {
                border.show(around: Geometry.flip(frame), width: config.borderWidth,
                            radii: CornerRadii(uniform: 16), color: config.activeBorderColor)
            }
        }
        measure("layout (no-op)", 20) { layout() }
        measure("read all frames", 20) { for w in active { _ = w.element.frame } }
        measure("notifyWorkspaceChange", 100) { notifyWorkspaceChange() }

        // Simulates dragging a window edge: the border overlay resizes every event.
        if let screen = Geometry.primaryScreen {
            let full = screen.visibleFrame
            var i = 0
            measure("border resize (drag)", 120) {
                i += 1
                let inset = CGFloat(i % 60) * 4
                border.show(around: full.insetBy(dx: inset, dy: inset / 2), width: config.borderWidth,
                            radii: CornerRadii(uniform: 16), color: config.activeBorderColor)
            }
            updateBorder()
        }
    }
}

extension AXUIElement {
    func performRaise() {
        axCallCount += 1
        AXUIElementPerformAction(self, kAXRaiseAction as CFString)
    }
}
