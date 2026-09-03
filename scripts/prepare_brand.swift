import AppKit

// Render the supplied SVGs using macOS's native SVG renderer. No background removal
// or redrawing is needed; alpha, gradients, paths, and installed fonts are preserved.
// Run from the repository root: swift scripts/prepare_brand.swift
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

func bitmap(width: Int, height: Int) -> NSBitmapImageRep {
    guard let result = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { fatalError("Cannot allocate \(width)×\(height) bitmap") }
    result.bitmapData?.initialize(repeating: 0, count: result.bytesPerRow * height)
    return result
}

func draw(_ image: NSImage, in rect: NSRect, on output: NSBitmapImageRep) {
    guard let context = NSGraphicsContext(bitmapImageRep: output) else {
        fatalError("Cannot create graphics context")
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
}

func render(_ svg: Data, destination: String, square: Bool, size: Int) throws {
    guard let image = NSImage(data: svg), image.isValid else { fatalError("Invalid SVG") }
    let width = Int(image.size.width * 2), height = Int(image.size.height * 2)
    let source = bitmap(width: width, height: height)
    draw(image, in: NSRect(x: 0, y: 0, width: width, height: height), on: source)

    // Trim only transparent margins. Pixel bounds include the SVG's translucent seam.
    var minX = width, minY = height, maxX = -1, maxY = -1
    guard let pixels = source.bitmapData else { fatalError("Cannot read rendered pixels") }
    for y in 0..<height {
        for x in 0..<width where pixels[y * source.bytesPerRow + x * 4 + 3] > 0 {
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
        }
    }
    guard maxX >= minX, maxY >= minY,
          let cropped = source.cgImage?.cropping(to: CGRect(
            x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1
          )) else { fatalError("SVG has no visible artwork") }

    let padding = Int(ceil(Double(size) * (square ? 0.06 : 0.015)))
    let scale = CGFloat(size - padding * 2) / CGFloat(square ? max(cropped.width, cropped.height) : cropped.width)
    let contentWidth = CGFloat(cropped.width) * scale
    let contentHeight = CGFloat(cropped.height) * scale
    let outputHeight = square ? size : Int(ceil(contentHeight)) + padding * 2
    let output = bitmap(width: size, height: outputHeight)
    draw(NSImage(cgImage: cropped, size: .zero),
         in: NSRect(x: (CGFloat(size) - contentWidth) / 2,
                    y: (CGFloat(outputHeight) - contentHeight) / 2,
                    width: contentWidth, height: contentHeight), on: output)
    guard let png = output.representation(using: .png, properties: [:]) else {
        fatalError("Cannot encode \(destination)")
    }
    try png.write(to: root.appendingPathComponent(destination))
    print("\(destination): \(size)×\(outputHeight), transparent PNG")
}

let icon = try Data(contentsOf: root.appendingPathComponent("assets/brand/veyra-icon.svg"))
let logo = try Data(contentsOf: root.appendingPathComponent("assets/brand/veyra-logo.svg"))
try render(icon, destination: "Veyra/Resources/VeyraMark.png", square: true, size: 1024)
try render(logo, destination: "assets/brand/veyra-logo-preview.png", square: false, size: 1200)

// Keep the SVG's typography as a separate template image so its color follows
// the system appearance while the adjacent brand mark retains its gradient.
let wordmark = try XMLDocument(data: logo)
for group in try wordmark.nodes(forXPath: "/*[local-name()='svg']/*[local-name()='g']") {
    group.detach()
}
try render(wordmark.xmlData, destination: "Veyra/Resources/VeyraWordmark.png", square: false, size: 800)

let darkLogo = try XMLDocument(data: logo)
for case let text as XMLElement in try darkLogo.nodes(forXPath: "//*[local-name()='text']") {
    text.attribute(forName: "fill")?.stringValue = "#F4F3EF"
}
try render(darkLogo.xmlData, destination: "assets/brand/veyra-logo-preview-dark.png", square: false, size: 1200)
