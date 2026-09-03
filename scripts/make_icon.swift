import AppKit

// Native vector drawing; deterministic Finder icon, no downloaded imagery.
let destination = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let side = CGFloat(pixels)
        let inset = side * 0.08
        let rect = NSRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
        let rounded = NSBezierPath(roundedRect: rect, xRadius: side * 0.19, yRadius: side * 0.19)
        NSGradient(starting: NSColor(calibratedRed: 0.10, green: 0.65, blue: 0.53, alpha: 1),
                   ending: NSColor(calibratedRed: 0.04, green: 0.35, blue: 0.32, alpha: 1))!.draw(in: rounded, angle: -90)
        let prompt = NSBezierPath()
        prompt.lineWidth = side * 0.055; prompt.lineCapStyle = .round; prompt.lineJoinStyle = .round
        prompt.move(to: NSPoint(x: side * 0.28, y: side * 0.61))
        prompt.line(to: NSPoint(x: side * 0.42, y: side * 0.50))
        prompt.line(to: NSPoint(x: side * 0.28, y: side * 0.39))
        NSColor.white.setStroke(); prompt.stroke()
        let line = NSBezierPath()
        line.lineWidth = side * 0.055; line.lineCapStyle = .round
        line.move(to: NSPoint(x: side * 0.53, y: side * 0.39))
        line.line(to: NSPoint(x: side * 0.71, y: side * 0.39))
        line.stroke()
        image.unlockFocus()
        let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        let bitmap = NSBitmapImageRep(cgImage: cg)
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: destination.appendingPathComponent(name))
    }
}
