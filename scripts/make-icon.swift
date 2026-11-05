// Renders the Blinker app icon and builds Resources/AppIcon.icns.
//   swift scripts/make-icon.swift
// Drawn by hand (not an SF Symbol: Apple's license doesn't allow those in app icons), and a
// generic security key rather than any vendor's product.
import AppKit

let size: CGFloat = 1024
let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources")

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func render() -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    defer { NSGraphicsContext.current = nil }

    // macOS icon grid: 824pt rounded square centered on a 1024 canvas.
    let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = .black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = 28
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    color(0x151B2B).setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGradient(colors: [color(0x2C3A58), color(0x131A2A)])!.draw(in: shape, angle: -90)

    // Soft top sheen.
    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    NSGradient(colors: [.white.withAlphaComponent(0.10), .white.withAlphaComponent(0)])!
        .draw(in: NSRect(x: tile.minX, y: tile.midY, width: tile.width, height: tile.height / 2), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    let body = NSRect(x: tile.midX - 150, y: 250, width: 300, height: 470)
    let pad = NSPoint(x: body.midX, y: body.midY + 40)
    // Blink rings radiating from the touch pad, behind the key: the moment Blinker is about.
    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    for (i, radius) in [175.0, 245.0, 315.0].enumerated() {
        let ring = NSBezierPath(ovalIn: NSRect(x: pad.x - radius, y: pad.y - radius, width: radius * 2, height: radius * 2))
        ring.lineWidth = 18 - CGFloat(i) * 4
        color(0xFFB340, 0.55 - CGFloat(i) * 0.16).setStroke()
        ring.stroke()
    }
    NSGraphicsContext.restoreGraphicsState()

    // The key, standing upright: a USB-C plug at the bottom, the body, and a touch pad near the top.
    let plug = NSRect(x: tile.midX - 70, y: 170, width: 140, height: 100)
    let plugPath = NSBezierPath(roundedRect: plug, xRadius: 26, yRadius: 26)
    NSGradient(colors: [color(0xC9D1DE), color(0x8B95A7)])!.draw(in: plugPath, angle: 0)
    color(0x5A6478).setFill()
    NSBezierPath(roundedRect: NSRect(x: plug.midX - 40, y: plug.minY + 22, width: 80, height: 18), xRadius: 9, yRadius: 9).fill()

    let bodyPath = NSBezierPath(roundedRect: body, xRadius: 70, yRadius: 70)
    NSGraphicsContext.saveGraphicsState()
    let bodyShadow = NSShadow()
    bodyShadow.shadowColor = .black.withAlphaComponent(0.45)
    bodyShadow.shadowBlurRadius = 24
    bodyShadow.shadowOffset = NSSize(width: 0, height: -10)
    bodyShadow.set()
    color(0x1B2233).setFill()
    bodyPath.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [color(0x3A4766), color(0x232C42)])!.draw(in: bodyPath, angle: -90)
    color(0xFFFFFF, 0.14).setStroke()
    bodyPath.lineWidth = 4
    bodyPath.stroke()

    // Keyring hole.
    color(0x131A2A).setFill()
    NSBezierPath(roundedRect: NSRect(x: body.midX - 45, y: body.maxY - 78, width: 90, height: 36), xRadius: 18, yRadius: 18).fill()

    NSGraphicsContext.saveGraphicsState()
    // The touch pad, glowing amber.
    let glow = NSShadow()
    glow.shadowColor = color(0xFFB340, 0.95)
    glow.shadowBlurRadius = 60
    glow.set()
    let padRect = NSRect(x: pad.x - 95, y: pad.y - 95, width: 190, height: 190)
    NSGradient(colors: [color(0xFFD27A), color(0xFF9F0A)])!.draw(in: NSBezierPath(ovalIn: padRect), angle: -90)
    NSGraphicsContext.restoreGraphicsState()
    color(0xFFFFFF, 0.35).setFill()
    NSBezierPath(ovalIn: NSRect(x: pad.x - 50, y: pad.y + 22, width: 70, height: 42)).fill()
    color(0xB86A00, 0.6).setStroke()
    let padRing = NSBezierPath(ovalIn: padRect.insetBy(dx: 26, dy: 26))
    padRing.lineWidth = 6
    padRing.stroke()
    return rep
}

let rep = render()
let fm = FileManager.default
let iconset = fm.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
try fm.createDirectory(at: out, withIntermediateDirectories: true)

let png = rep.representation(using: .png, properties: [:])!
let master = iconset.appendingPathComponent("master.png")
try png.write(to: master)
try png.write(to: out.appendingPathComponent("AppIcon.png"))

func run(_ path: String, _ args: [String]) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice
    try! p.run()
    p.waitUntilExit()
}

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let name = "icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"
        run("/usr/bin/sips", ["-z", "\(px)", "\(px)", master.path, "--out", iconset.appendingPathComponent(name).path])
    }
}
try fm.removeItem(at: master)
run("/usr/bin/iconutil", ["-c", "icns", iconset.path, "-o", out.appendingPathComponent("AppIcon.icns").path])
print("Wrote \(out.path)/AppIcon.icns")
