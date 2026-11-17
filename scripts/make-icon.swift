// Draws the app icon and writes Resources/AppIcon.icns.
// Usage: swift scripts/make-icon.swift   (from the repo root)
//
// Design: a Mission Control–blue squircle with a grid of window thumbnails;
// the front one carries the red close button the app adds.
import AppKit

func drawIcon(size s: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(s), pixelsHigh: Int(s),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let u = s / 1024  // design units

    // Background squircle (Apple's grid: 824pt body inside a 1024 canvas).
    let body = NSRect(x: 100 * u, y: 100 * u, width: 824 * u, height: 824 * u)
    let squircle = NSBezierPath(roundedRect: body, xRadius: 185 * u, yRadius: 185 * u)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(white: 0, alpha: 0.35)
    shadow.shadowOffset = NSSize(width: 0, height: -10 * u)
    shadow.shadowBlurRadius = 24 * u
    shadow.set()
    NSColor(red: 0.10, green: 0.32, blue: 0.75, alpha: 1).setFill()
    squircle.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [NSColor(red: 0.20, green: 0.52, blue: 0.98, alpha: 1),
                        NSColor(red: 0.07, green: 0.24, blue: 0.62, alpha: 1)])!
        .draw(in: squircle, angle: -90)

    // Window thumbnails.
    func window(_ r: NSRect, alpha: CGFloat) {
        let path = NSBezierPath(roundedRect: r, xRadius: 26 * u, yRadius: 26 * u)
        NSGraphicsContext.saveGraphicsState()
        let sh = NSShadow()
        sh.shadowColor = NSColor(white: 0, alpha: 0.30 * alpha)
        sh.shadowOffset = NSSize(width: 0, height: -6 * u)
        sh.shadowBlurRadius = 14 * u
        sh.set()
        NSColor(white: 0.97, alpha: alpha).setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
        // Title bar.
        let bar = NSRect(x: r.minX, y: r.maxY - 46 * u, width: r.width, height: 46 * u)
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        NSColor(white: 0.84, alpha: alpha).setFill()
        bar.fill()
        NSGraphicsContext.restoreGraphicsState()
    }
    window(NSRect(x: 170 * u, y: 560 * u, width: 300 * u, height: 210 * u), alpha: 0.75)
    window(NSRect(x: 554 * u, y: 560 * u, width: 300 * u, height: 210 * u), alpha: 0.75)
    window(NSRect(x: 170 * u, y: 250 * u, width: 300 * u, height: 210 * u), alpha: 0.75)
    let front = NSRect(x: 470 * u, y: 200 * u, width: 400 * u, height: 290 * u)
    window(front, alpha: 1)

    // Close button on the front window's top-left corner.
    let c = NSPoint(x: front.minX + 6 * u, y: front.maxY - 6 * u)
    let r: CGFloat = 92 * u
    let circle = NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
    NSGraphicsContext.saveGraphicsState()
    let sh = NSShadow()
    sh.shadowColor = NSColor(white: 0, alpha: 0.4)
    sh.shadowOffset = NSSize(width: 0, height: -6 * u)
    sh.shadowBlurRadius = 16 * u
    sh.set()
    NSColor(red: 0.96, green: 0.26, blue: 0.24, alpha: 1).setFill()
    circle.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSColor.white.setStroke()
    circle.lineWidth = 12 * u
    circle.stroke()
    let x = NSBezierPath()
    let i = r * 0.42
    x.move(to: NSPoint(x: c.x - i, y: c.y - i)); x.line(to: NSPoint(x: c.x + i, y: c.y + i))
    x.move(to: NSPoint(x: c.x - i, y: c.y + i)); x.line(to: NSPoint(x: c.x + i, y: c.y - i))
    x.lineWidth = 26 * u
    x.lineCapStyle = .round
    x.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let fm = FileManager.default
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = CGFloat(base * scale)
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try drawIcon(size: px).representation(using: .png, properties: [:])!
            .write(to: iconset.appendingPathComponent(name))
    }
}
try fm.createDirectory(atPath: "Resources", withIntermediateDirectories: true)
try drawIcon(size: 1024).representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: "Resources/AppIcon.png"))

let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try p.run()
p.waitUntilExit()
print(p.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
