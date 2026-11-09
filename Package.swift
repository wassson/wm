// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "wm",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure logic (config, TOML, layout, icons) — no AppKit, fully unit-testable.
        .target(name: "WMCore", path: "Sources/WMCore"),
        // The window manager app itself (AppKit + Accessibility + Carbon hotkeys).
        .executableTarget(name: "wm", dependencies: ["WMCore"], path: "Sources/wm"),
        .testTarget(name: "WMCoreTests", dependencies: ["WMCore"], path: "Tests/WMCoreTests"),
    ]
)
