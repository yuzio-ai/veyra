import AppKit

// Package the transparent Veyra mark into the standard macOS iconset sizes.
// Usage: swift scripts/make_icon.swift Veyra/Resources/VeyraMark.png build/Veyra.iconset
guard CommandLine.arguments.count == 3,
      let mark = NSImage(contentsOfFile: CommandLine.arguments[1]) else {
    fatalError("Usage: swift scripts/make_icon.swift <transparent-mark.png> <output.iconset>")
}
let destination = URL(fileURLWithPath: CommandLine.arguments[2])
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let side = CGFloat(pixels)
        // Explicit pixels keep the exported sizes independent of the display's Retina scale.
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            fatalError("Unable to create \(pixels)px icon bitmap")
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        let canvas = NSRect(x: 0, y: 0, width: side, height: side)
        NSColor.clear.setFill()
        canvas.fill(using: .copy)
        let plate = NSBezierPath(roundedRect: canvas.insetBy(dx: side * 0.08, dy: side * 0.08),
                                 xRadius: side * 0.19, yRadius: side * 0.19)
        NSColor(srgbRed: 0.985, green: 0.980, blue: 0.970, alpha: 1).setFill()
        plate.fill()
        let markSize = side * 0.72
        mark.draw(in: NSRect(x: (side - markSize) / 2, y: (side - markSize) / 2,
                            width: markSize, height: markSize),
                  from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            fatalError("Unable to encode \(name)")
        }
        try data.write(to: destination.appendingPathComponent(name))
    }
}
