// Draws Clipload's app icon into an .iconset folder: swift makeicon.swift <out.iconset>

import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let s = CGFloat(px)
    // macOS icon grid: the rounded square sits inside a ~10% margin.
    let inset = s * 0.098
    let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let tile = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)

    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = s * 0.025
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.012)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    NSColor.black.setFill()
    tile.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGradient(colors: [
        NSColor(srgbRed: 0.36, green: 0.62, blue: 1.00, alpha: 1),
        NSColor(srgbRed: 0.22, green: 0.38, blue: 0.98, alpha: 1),
        NSColor(srgbRed: 0.45, green: 0.26, blue: 0.93, alpha: 1),
    ])!.draw(in: tile, angle: -90)

    // Down arrow into a tray.
    let h = rect.height
    let cx = rect.midX
    let white = NSColor.white
    white.setStroke()

    let stroke = { (path: NSBezierPath) in
        path.lineWidth = h * 0.085
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()
    }

    let tipY = rect.minY + h * 0.36
    let shaft = NSBezierPath()
    shaft.move(to: NSPoint(x: cx, y: rect.maxY - h * 0.22))
    shaft.line(to: NSPoint(x: cx, y: tipY + h * 0.02))
    stroke(shaft)

    let head = NSBezierPath()
    head.move(to: NSPoint(x: cx - h * 0.17, y: tipY + h * 0.17))
    head.line(to: NSPoint(x: cx, y: tipY))
    head.line(to: NSPoint(x: cx + h * 0.17, y: tipY + h * 0.17))
    stroke(head)

    let tray = NSBezierPath()
    tray.move(to: NSPoint(x: cx - h * 0.27, y: rect.minY + h * 0.30))
    tray.line(to: NSPoint(x: cx - h * 0.27, y: rect.minY + h * 0.21))
    tray.line(to: NSPoint(x: cx + h * 0.27, y: rect.minY + h * 0.21))
    tray.line(to: NSPoint(x: cx + h * 0.27, y: rect.minY + h * 0.30))
    stroke(tray)

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: out.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
