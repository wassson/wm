// Generates Support/AppIcon.icns: the menu bar domino tile, showing nine pips,
// on a macOS-style rounded-square background.
//
//   swift scripts/make-icon.swift
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
let output = root.appendingPathComponent("Support/AppIcon.icns")

/// Draws the icon on a 1024×1024 canvas (y up).
func drawIcon() {
    // Background: Apple's icon grid puts the body at 824pt with a ~185pt corner radius.
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = 24
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.set()
    NSColor.black.setFill()
    bodyPath.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGradient(colors: [NSColor(srgbRed: 0.20, green: 0.22, blue: 0.27, alpha: 1),
                        NSColor(srgbRed: 0.07, green: 0.08, blue: 0.10, alpha: 1)])!
        .draw(in: bodyPath, angle: -90)

    // Domino tile: the 16pt menu bar icon scaled up (tile 14.5pt, stroke 1.25pt,
    // radius 3.5pt, pip grid inset 3.6pt), centered in the body.
    let scale: CGFloat = 520 / 14.5
    let tile = NSRect(x: 512 - 260, y: 512 - 260, width: 520, height: 520)
    let outline = NSBezierPath(roundedRect: tile, xRadius: 3.5 * scale, yRadius: 3.5 * scale)
    outline.lineWidth = 1.25 * scale
    NSColor.white.setStroke()
    outline.stroke()

    let grid = tile.insetBy(dx: 3.6 * scale, dy: 3.6 * scale)
    let r = 1.35 * scale
    NSColor.white.setFill()
    for column in 0...2 {
        for row in 0...2 {
            let x = grid.minX + CGFloat(column) * grid.width / 2
            let y = grid.minY + CGFloat(row) * grid.height / 2
            NSBezierPath(ovalIn: NSRect(x: x - r, y: y - r, width: r * 2, height: r * 2)).fill()
        }
    }
}

func png(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    let s = CGFloat(pixels) / 1024
    context.cgContext.scaleBy(x: s, y: s)
    drawIcon()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    try png(pixels: size).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try png(pixels: size * 2).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
try png(pixels: 1024).write(to: root.appendingPathComponent("Support/AppIcon.png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Wrote \(output.path)")
