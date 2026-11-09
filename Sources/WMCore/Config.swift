import Foundation

// MARK: - Bindings

public enum Direction: String, CaseIterable, Hashable, Sendable {
    case left, right, up, down
}

public enum Action: Hashable, Sendable {
    case workspace(Int)
    case moveToWorkspace(Int)
    case focus(Direction)
    case swap(Direction)
    case toggleFloat
    case reload
    /// Moves the divider beside the focused window in that direction.
    case moveSplit(Direction)

    /// Parses strings like "workspace 3", "movetoworkspace 3", "focus left",
    /// "swap right", "togglefloat", "reload".
    public init?(parsing text: String) {
        let parts = text.lowercased().split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard let command = parts.first else { return nil }
        let arg = parts.count == 2 ? parts[1] : nil

        switch command {
        case "workspace", "movetoworkspace":
            guard let arg, let n = Int(arg), (1...Config.maxWorkspaces).contains(n) else { return nil }
            self = command == "workspace" ? .workspace(n) : .moveToWorkspace(n)
        case "focus", "swap":
            guard let arg, let dir = Direction(rawValue: arg) else { return nil }
            self = command == "focus" ? .focus(dir) : .swap(dir)
        case "movesplit":
            guard let arg, let dir = Direction(rawValue: arg) else { return nil }
            self = .moveSplit(dir)
        case "togglefloat":
            guard parts.count == 1 else { return nil }
            self = .toggleFloat
        case "reload":
            guard parts.count == 1 else { return nil }
            self = .reload
        default:
            return nil
        }
    }
}

public struct Modifiers: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let command = Modifiers(rawValue: 1 << 0)
    public static let option = Modifiers(rawValue: 1 << 1)
    public static let control = Modifiers(rawValue: 1 << 2)
    public static let shift = Modifiers(rawValue: 1 << 3)
}

public struct KeyChord: Hashable, Sendable {
    public var modifiers: Modifiers
    public var keyCode: UInt32

    public init(modifiers: Modifiers, keyCode: UInt32) {
        self.modifiers = modifiers
        self.keyCode = keyCode
    }

    /// Parses chords like "alt+shift+1" or "cmd+ctrl+left".
    public init?(parsing text: String) {
        let tokens = text.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let keyName = tokens.last, let code = KeyCodes.code(for: keyName) else { return nil }
        var mods: Modifiers = []
        for token in tokens.dropLast() {
            switch token {
            case "cmd", "command", "super": mods.insert(.command)
            case "alt", "opt", "option": mods.insert(.option)
            case "ctrl", "control": mods.insert(.control)
            case "shift": mods.insert(.shift)
            default: return nil
            }
        }
        self.init(modifiers: mods, keyCode: code)
    }
}

public struct KeyBinding: Hashable, Sendable {
    public var chord: KeyChord
    public var action: Action

    public init(chord: KeyChord, action: Action) {
        self.chord = chord
        self.action = action
    }
}

// MARK: - Gaps

/// Per-side spacing, in points. Written in config as a single number or a
/// CSS-style array: [all], [vertical, horizontal], [top, horizontal, bottom]
/// or [top, right, bottom, left].
public struct Gaps: Hashable, Sendable, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral {
    public var top: Double, right: Double, bottom: Double, left: Double

    public init(top: Double, right: Double, bottom: Double, left: Double) {
        self.top = top
        self.right = right
        self.bottom = bottom
        self.left = left
    }

    public init(_ all: Double) { self.init(top: all, right: all, bottom: all, left: all) }
    public init(integerLiteral value: Int) { self.init(Double(value)) }
    public init(floatLiteral value: Double) { self.init(value) }

    /// CSS shorthand: 1–4 values.
    public init?(css v: [Double]) {
        switch v.count {
        case 1: self.init(v[0])
        case 2: self.init(top: v[0], right: v[1], bottom: v[0], left: v[1])
        case 3: self.init(top: v[0], right: v[1], bottom: v[2], left: v[1])
        case 4: self.init(top: v[0], right: v[1], bottom: v[2], left: v[3])
        default: return nil
        }
    }
}

// MARK: - Colors

public struct RGBA: Hashable, Sendable {
    public var red: Double, green: Double, blue: Double, alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// Accepts "#rrggbb" or "#rrggbbaa" (leading "#" or "0x" optional).
    public init?(hex: String) {
        var s = Substring(hex.trimmingCharacters(in: .whitespaces))
        if s.hasPrefix("#") { s = s.dropFirst() } else if s.lowercased().hasPrefix("0x") { s = s.dropFirst(2) }
        guard s.count == 6 || s.count == 8, s.allSatisfy(\.isHexDigit), let v = UInt64(s, radix: 16) else {
            return nil
        }
        func byte(_ shift: UInt64) -> Double { Double((v >> shift) & 0xFF) / 255 }
        if s.count == 6 {
            self.init(red: byte(16), green: byte(8), blue: byte(0))
        } else {
            self.init(red: byte(24), green: byte(16), blue: byte(8), alpha: byte(0))
        }
    }
}

// MARK: - Config

public struct Config: Equatable, Sendable {
    public static let maxWorkspaces = 9

    /// Pixels between adjacent tiled windows.
    public var gapsIn: Double = 2
    /// Pixels between tiled windows and the edges of the screen.
    public var gapsOut: Gaps = 2
    /// Number of workspaces, 1...9.
    public var workspaceCount: Int = Config.maxWorkspaces
    /// How far one keypress moves a divider, as a fraction of the space it divides.
    public var resizeStep: Double = 0.05
    /// Start wm automatically when you log in (macOS Login Items).
    public var launchAtLogin = false
    /// Bundle identifiers whose windows always float.
    public var floatingApps: [String] = ["com.apple.systempreferences"]

    public var borderEnabled = true
    public var borderWidth: Double = 2
    public var borderRadius: Double = 14
    /// Bottom corners of a window sitting in the display's bottom corners follow
    /// the display's own rounded corners.
    public var matchDisplayCorners = true
    /// Per-app overrides of `borderRadius`, keyed by lowercased app name or bundle ID.
    public var appBorderRadius: [String: Double] = [:]
    public var activeBorderColor = RGBA(red: 0x89 / 255, green: 0xB4 / 255, blue: 0xFA / 255)

    public var bindings: [KeyBinding] = Config.defaultBindings

    public init() {}
}

public struct ConfigError: Error, CustomStringConvertible, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

public struct ConfigParseResult: Sendable {
    public let config: Config
    /// Non-fatal problems such as unknown keys.
    public let warnings: [String]
}

extension Config {
    /// Parses a config file. Missing keys keep their defaults; invalid values throw
    /// (so the caller can keep the previous working config); unknown keys produce warnings.
    public static func parse(_ text: String) throws -> ConfigParseResult {
        let root = try TOML.parse(text)
        var c = Config()
        var warnings: [String] = []

        for (section, value) in root.sorted(by: { $0.key < $1.key }) {
            guard let table = value.table else {
                warnings.append("unknown top-level key '\(section)' (expected a [section])")
                continue
            }
            switch section {
            case "general":
                for (key, v) in table.sorted(by: { $0.key < $1.key }) {
                    let name = "general.\(key)"
                    switch key {
                    case "gaps_in": c.gapsIn = try number(v, name, min: 0)
                    case "gaps_out": c.gapsOut = try gaps(v, name)
                    case "workspaces": c.workspaceCount = try Int(number(v, name, min: 1, max: Double(maxWorkspaces), integer: true))
                    case "floating_apps": c.floatingApps = try strings(v, name)
                    case "launch_at_login": c.launchAtLogin = try bool(v, name)
                    case "resize_step": c.resizeStep = try number(v, name, min: 0.01, max: 0.5)
                    default: warnings.append("unknown key '\(name)'")
                    }
                }
            case "border":
                for (key, v) in table.sorted(by: { $0.key < $1.key }) {
                    let name = "border.\(key)"
                    switch key {
                    case "enabled": c.borderEnabled = try bool(v, name)
                    case "width": c.borderWidth = try number(v, name, min: 0, max: 50)
                    case "radius": c.borderRadius = try number(v, name, min: 0, max: 100)
                    case "match_display_corners": c.matchDisplayCorners = try bool(v, name)
                    case "app_radius":
                        guard let apps = v.table else {
                            throw ConfigError("[border.app_radius] must be a table of \"App Name\" = radius")
                        }
                        for (app, r) in apps {
                            c.appBorderRadius[app.lowercased()] = try number(r, "border.app_radius.\"\(app)\"", min: 0, max: 100)
                        }
                    case "active_color":
                        guard let s = v.string, let color = RGBA(hex: s) else {
                            throw ConfigError("\(name) must be a color like \"#89b4fa\" or \"#89b4faff\"")
                        }
                        c.activeBorderColor = color
                    default: warnings.append("unknown key '\(name)'")
                    }
                }
            case "binds":
                c.bindings = try parseBinds(table)
            default:
                warnings.append("unknown section [\(section)]")
            }
        }

        for binding in c.bindings {
            switch binding.action {
            case .workspace(let n), .moveToWorkspace(let n):
                if n > c.workspaceCount {
                    warnings.append("binding for workspace \(n) exceeds general.workspaces (\(c.workspaceCount)) and will be ignored")
                }
            default: break
            }
        }

        return ConfigParseResult(config: c, warnings: warnings)
    }

    static func parseBinds(_ table: [String: TOMLValue]) throws -> [KeyBinding] {
        var bindings: [KeyBinding] = []
        var seen: [KeyChord: String] = [:]
        for (key, value) in table.sorted(by: { $0.key < $1.key }) {
            guard let chord = KeyChord(parsing: key) else {
                throw ConfigError("binds: invalid key chord \"\(key)\"")
            }
            guard let text = value.string, let action = Action(parsing: text) else {
                throw ConfigError("binds: invalid action for \"\(key)\" (expected e.g. \"workspace 1\", \"focus left\", \"togglefloat\")")
            }
            if let other = seen[chord] {
                throw ConfigError("binds: \"\(key)\" and \"\(other)\" are the same chord")
            }
            seen[chord] = key
            bindings.append(KeyBinding(chord: chord, action: action))
        }
        return bindings
    }

    private static func number(_ v: TOMLValue, _ name: String, min: Double? = nil, max: Double? = nil, integer: Bool = false) throws -> Double {
        guard let d = v.double else { throw ConfigError("\(name) must be a number") }
        if integer, v.int == nil { throw ConfigError("\(name) must be a whole number") }
        if let min, d < min { throw ConfigError("\(name) must be at least \(format(min))") }
        if let max, d > max { throw ConfigError("\(name) must be at most \(format(max))") }
        return d
    }

    private static func gaps(_ v: TOMLValue, _ name: String) throws -> Gaps {
        let message = "\(name) must be a number or an array of 1-4 numbers [top, right, bottom, left], each at least 0"
        let values: [Double]
        if let d = v.double {
            values = [d]
        } else if let items = v.array {
            values = try items.map { guard let d = $0.double else { throw ConfigError(message) }; return d }
        } else {
            throw ConfigError(message)
        }
        guard values.allSatisfy({ $0 >= 0 }), let gaps = Gaps(css: values) else { throw ConfigError(message) }
        return gaps
    }

    private static func bool(_ v: TOMLValue, _ name: String) throws -> Bool {
        guard let b = v.bool else { throw ConfigError("\(name) must be true or false") }
        return b
    }

    private static func strings(_ v: TOMLValue, _ name: String) throws -> [String] {
        guard let items = v.array else { throw ConfigError("\(name) must be an array of strings") }
        return try items.map {
            guard let s = $0.string else { throw ConfigError("\(name) must be an array of strings") }
            return s
        }
    }

    private static func format(_ d: Double) -> String {
        d == d.rounded() ? String(Int(d)) : String(d)
    }
}

extension Config {
    /// The window corner radius the border wraps around for an app: a per-app override
    /// matched by bundle ID or app name (case-insensitive), else `borderRadius`.
    public func borderRadius(bundleID: String?, appName: String?) -> Double {
        for key in [bundleID, appName].compactMap({ $0?.lowercased() }) {
            if let r = appBorderRadius[key] { return r }
        }
        return borderRadius
    }
}

// MARK: - Defaults

extension Config {
    public static let defaultBindings: [KeyBinding] = {
        do {
            guard let binds = try TOML.parse(defaultTOML)["binds"]?.table else { return [] }
            return try parseBinds(binds)
        } catch {
            preconditionFailure("default config is invalid: \(error)")
        }
    }()

    /// Written to ~/.config/wm/config.toml on first launch.
    public static let defaultTOML = """
    # wm configuration
    # Changes are applied automatically when this file is saved.

    [general]
    gaps_in = 2       # pixels between adjacent windows
    gaps_out = 2      # pixels between windows and the screen edges; a number, or
                      # [top, right, bottom, left] e.g. [0, 2, 2, 2]
    workspaces = 9    # number of workspaces (1-9)
    launch_at_login = false   # start wm when you log in (shows under Login Items)
    resize_step = 0.05        # how far each movesplit keypress moves a divider (5%)
    # Bundle IDs of apps whose windows float instead of tiling.
    # (Find one with: osascript -e 'id of app "App Name"')
    floating_apps = ["com.apple.systempreferences"]

    [border]
    enabled = true
    width = 2
    radius = 14                 # window corner radius the border wraps around
    # Windows tucked into the display's bottom-left/right corners get a border that
    # follows the display's own rounded corner instead.
    match_display_corners = true
    active_color = "#89b4fa"    # "#rrggbb" or "#rrggbbaa"

    # Per-app window corner radius, for apps rounder or squarer than "radius".
    # Keys are app names or bundle IDs.
    [border.app_radius]
    # "Rex Beta" = 26

    # Key bindings: "modifiers+key" = "action"
    #   modifiers: cmd, alt (option), ctrl, shift
    #   keys:      a-z, 0-9, left/right/up/down, space, return, tab, escape, f1-f12, ...
    #   actions:   workspace N | movetoworkspace N | focus DIR | swap DIR | togglefloat | reload
    #              movesplit DIR (moves the divider beside the focused window)
    #              (DIR is left, right, up or down)
    # Defining this section replaces all default bindings.
    [binds]
    "alt+1" = "workspace 1"
    "alt+2" = "workspace 2"
    "alt+3" = "workspace 3"
    "alt+4" = "workspace 4"
    "alt+5" = "workspace 5"
    "alt+6" = "workspace 6"
    "alt+7" = "workspace 7"
    "alt+8" = "workspace 8"
    "alt+9" = "workspace 9"

    "alt+shift+1" = "movetoworkspace 1"
    "alt+shift+2" = "movetoworkspace 2"
    "alt+shift+3" = "movetoworkspace 3"
    "alt+shift+4" = "movetoworkspace 4"
    "alt+shift+5" = "movetoworkspace 5"
    "alt+shift+6" = "movetoworkspace 6"
    "alt+shift+7" = "movetoworkspace 7"
    "alt+shift+8" = "movetoworkspace 8"
    "alt+shift+9" = "movetoworkspace 9"

    "alt+h" = "focus left"
    "alt+j" = "focus down"
    "alt+k" = "focus up"
    "alt+l" = "focus right"

    "alt+shift+h" = "swap left"
    "alt+shift+j" = "swap down"
    "alt+shift+k" = "swap up"
    "alt+shift+l" = "swap right"

    "alt+shift+space" = "togglefloat"
    "alt+shift+r" = "reload"

    "cmd+1" = "workspace 1"
    "cmd+2" = "workspace 2"
    "cmd+3" = "workspace 3"
    "cmd+4" = "workspace 4"
    "cmd+5" = "workspace 5"
    "cmd+6" = "workspace 6"
    "cmd+7" = "workspace 7"
    "cmd+8" = "workspace 8"
    "cmd+9" = "workspace 9"

    "cmd+shift+1" = "movetoworkspace 1"
    "cmd+shift+2" = "movetoworkspace 2"
    "cmd+shift+3" = "movetoworkspace 3"
    "cmd+shift+4" = "movetoworkspace 4"
    "cmd+shift+5" = "movetoworkspace 5"
    "cmd+shift+6" = "movetoworkspace 6"
    "cmd+shift+7" = "movetoworkspace 7"
    "cmd+shift+8" = "movetoworkspace 8"
    "cmd+shift+9" = "movetoworkspace 9"

    "cmd+left" = "focus left"
    "cmd+down" = "focus down"
    "cmd+up" = "focus up"
    "cmd+right" = "focus right"

    "cmd+shift+left" = "swap left"
    "cmd+shift+down" = "swap down"
    "cmd+shift+up" = "swap up"
    "cmd+shift+right" = "swap right"

    "cmd+]" = "movesplit right"
    "cmd+[" = "movesplit left"
    "cmd+shift+]" = "movesplit down"
    "cmd+shift+[" = "movesplit up"

    """
}
