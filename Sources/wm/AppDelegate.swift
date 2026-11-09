import AppKit
import ApplicationServices
import ServiceManagement
import WMCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = ConfigStore()
    private let hotKeys = HotKeyCenter()
    private var statusBar: StatusBarController!
    private var watcher: ConfigWatcher?
    private var wm: WindowManager?
    private var trustTimer: Timer?
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        store.createIfMissing()
        store.reload(force: true)

        statusBar = StatusBarController(onReload: { [weak self] in self?.reloadConfig(force: true) })
        statusBar.update(WorkspaceStatus(active: 1, displays: [DisplayStatus(name: "", workspace: 1)], occupied: []))
        statusBar.setError(store.lastError)
        applyLaunchAtLogin()

        watcher = ConfigWatcher(url: ConfigStore.url) { [weak self] in self?.reloadConfig(force: false) }
        watcher?.start()

        installSignalHandlers()
        whenAccessibilityTrusted { [weak self] in self?.startWindowManager() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        wm?.revealAll()
    }

    // MARK: -

    private func startWindowManager() {
        let wm = WindowManager(config: store.config)
        wm.onWorkspaceChange = { [weak self] status in self?.statusBar.update(status) }
        self.wm = wm
        wm.start()

        hotKeys.handler = { [weak self] action in self?.perform(action) }
        registerHotKeys()
        log("started")
    }

    private func perform(_ action: Action) {
        guard let wm else { return }
        switch action {
        case .workspace(let n): wm.switchToWorkspace(n)
        case .moveToWorkspace(let n): wm.moveFocusedWindow(toWorkspace: n)
        case .focus(let direction): wm.focus(direction)
        case .swap(let direction): wm.swap(direction)
        case .toggleFloat: wm.toggleFloat()
        case .moveSplit(let direction): wm.moveSplit(direction)
        case .reload: reloadConfig(force: true)
        }
    }

    private func reloadConfig(force: Bool) {
        let changed = store.reload(force: force)
        statusBar.setError(store.lastError)
        guard changed else { return }
        applyLaunchAtLogin()
        wm?.apply(config: store.config)
        if wm != nil { registerHotKeys() }
    }

    private func registerHotKeys() {
        let failures = hotKeys.register(store.config.bindings)
        for failure in failures { log("could not register hotkey for \(failure)") }
    }

    /// Keeps macOS Login Items in sync with `general.launch_at_login`. Only the installed
    /// copy registers, so running a dev build from build/ never replaces the login item.
    private func applyLaunchAtLogin() {
        guard Bundle.main.bundleURL.path.hasPrefix("/Applications/") else { return }
        let service = SMAppService.mainApp
        let wanted = store.config.launchAtLogin
        do {
            switch (wanted, service.status) {
            case (true, .enabled), (false, .notRegistered), (false, .notFound):
                return
            case (true, _):
                try service.register()
            case (false, _):
                try service.unregister()
            }
            log("launch at login \(wanted ? "enabled" : "disabled") (status: \(service.status.rawValue))")
            if service.status == .requiresApproval {
                log("launch at login needs approval in System Settings › General › Login Items")
            }
        } catch {
            log("could not update launch at login: \(error.localizedDescription)")
        }
    }

    /// Prompts for Accessibility access if needed and waits until it's granted.
    private func whenAccessibilityTrusted(_ start: @escaping @MainActor () -> Void) {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        if AXIsProcessTrustedWithOptions(options) {
            start()
            return
        }
        log("waiting for Accessibility permission (System Settings › Privacy & Security › Accessibility)")
        trustTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard AXIsProcessTrusted() else { return }
                timer.invalidate()
                self?.trustTimer = nil
                start()
            }
        }
    }

    /// Ctrl-C / kill should also bring parked windows back on screen.
    private func installSignalHandlers() {
        for sig in [SIGINT, SIGTERM, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { MainActor.assumeIsolated { NSApp.terminate(nil) } }
            source.resume()
            signalSources.append(source)
        }
        signal(SIGUSR1, SIG_IGN)
        let bench = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        bench.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.wm?.runBenchmark() } }
        bench.resume()
        signalSources.append(bench)
    }
}
