import CoreServices
import Foundation
import WMCore
import os

let logger = Logger(subsystem: "local.wm", category: "wm")

func log(_ message: String) {
    logger.log("\(message, privacy: .public)")
    FileHandle.standardError.write(Data("[wm] \(message)\n".utf8))
}

/// Owns ~/.config/wm/config.toml: creates it with defaults, parses it, and keeps
/// the last good config when an edit introduces an error.
@MainActor
final class ConfigStore {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/wm/config.toml")

    private(set) var config = Config()
    private(set) var lastError: String?
    private var lastText: String?

    func createIfMissing() {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: Self.url.path) else { return }
        do {
            try fm.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Config.defaultTOML.write(to: Self.url, atomically: true, encoding: .utf8)
            log("wrote default config to \(Self.url.path)")
        } catch {
            log("could not write default config: \(error)")
        }
    }

    /// Re-reads the file. Returns true when a new valid config was loaded.
    /// Unless `force` is set, an unchanged file is a no-op.
    @discardableResult
    func reload(force: Bool = false) -> Bool {
        guard let text = try? String(contentsOf: Self.url, encoding: .utf8) else {
            // Mid-save (atomic rename) or deleted: keep the current config.
            if force { lastError = "cannot read \(Self.url.path)" }
            return false
        }
        if !force && text == lastText { return false }
        lastText = text

        do {
            let result = try Config.parse(text)
            for warning in result.warnings { log("config warning: \(warning)") }
            config = result.config
            lastError = nil
            log("config loaded")
            return true
        } catch {
            lastError = "\(error)"
            log("config error (keeping previous config): \(error)")
            return false
        }
    }
}

/// Watches the config file's directory with FSEvents. Directory-level watching
/// survives editors that save by writing a temp file and renaming it over the original.
/// If config.toml is a symlink (dotfiles), the link target's directory is watched too.
@MainActor
final class ConfigWatcher {
    private let url: URL
    private let onChange: @MainActor () -> Void
    private var stream: FSEventStreamRef?

    init(url: URL, onChange: @escaping @MainActor () -> Void) {
        self.url = url
        self.onChange = onChange
    }

    func start() {
        stop()
        let dirs = Set([
            url.deletingLastPathComponent().resolvingSymlinksInPath().path,
            url.resolvingSymlinksInPath().deletingLastPathComponent().path,
        ])

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<ConfigWatcher>.fromOpaque(info).takeUnretainedValue()
            MainActor.assumeIsolated { watcher.onChange() }
        }
        guard let stream = FSEventStreamCreate(
            nil, callback, &context, Array(dirs) as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.15,  // latency: coalesces the burst of events from a single save
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        ) else {
            log("could not watch config directory")
            return
        }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}
