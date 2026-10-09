import Cocoa

// Draws the app icon at a given pixel size and writes a PNG.
func render(_ px: Int, to path: String) {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // Background squircle with gradient
    let inset = s * 0.05
    let bg = NSBezierPath(roundedRect: NSRect(x: inset, y: inset, width: s - 2*inset, height: s - 2*inset),
                          xRadius: s * 0.22, yRadius: s * 0.22)
    NSGradient(starting: NSColor(red: 0.20, green: 0.78, blue: 0.55, alpha: 1),
               ending: NSColor(red: 0.05, green: 0.40, blue: 0.45, alpha: 1))!.draw(in: bg, angle: -90)

    // Drive body
    let w = s * 0.62, h = s * 0.40
    let body = NSRect(x: (s - w)/2, y: s * 0.30, width: w, height: h)
    let drive = NSBezierPath(roundedRect: body, xRadius: s * 0.06, yRadius: s * 0.06)
    NSColor.white.setFill(); drive.fill()

    // Drive slot lines
    NSColor(white: 0.80, alpha: 1).setFill()
    for i in 0..<3 {
        NSBezierPath(roundedRect: NSRect(x: body.minX + s*0.05, y: body.minY + s*0.05 + CGFloat(i)*s*0.045,
                                         width: w * 0.55, height: s * 0.018),
                     xRadius: s*0.009, yRadius: s*0.009).fill()
    }
    // Green "alive" LED
    NSColor(red: 0.10, green: 0.75, blue: 0.40, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: body.maxX - s*0.11, y: body.minY + s*0.05, width: s*0.055, height: s*0.055)).fill()

    // Heartbeat line above the drive
    let hb = NSBezierPath()
    let y0 = s * 0.80, x0 = s * 0.22, x1 = s * 0.78, u = (x1 - x0) / 10
    hb.move(to: NSPoint(x: x0, y: y0))
    hb.line(to: NSPoint(x: x0 + 3*u, y: y0))
    hb.line(to: NSPoint(x: x0 + 4*u, y: y0 + s*0.07))
    hb.line(to: NSPoint(x: x0 + 5.2*u, y: y0 - s*0.07))
    hb.line(to: NSPoint(x: x0 + 6.2*u, y: y0))
    hb.line(to: NSPoint(x: x1, y: y0))
    hb.lineWidth = s * 0.028; hb.lineCapStyle = .round; hb.lineJoinStyle = .round
    NSColor.white.setStroke(); hb.stroke()

    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

let dir = CommandLine.arguments[1]
for (name, px) in [("16x16",16),("16x16@2x",32),("32x32",32),("32x32@2x",64),("128x128",128),("128x128@2x",256),
                   ("256x256",256),("256x256@2x",512),("512x512",512),("512x512@2x",1024)] {
    render(px, to: "\(dir)/icon_\(name).png")
}
