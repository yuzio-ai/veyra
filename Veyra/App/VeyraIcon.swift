import AppKit
import SwiftUI

/// Veyra's supplied brand mark, with a template variant for the system menu bar.
struct VeyraIcon: View {
    var size: CGFloat = 18
    var isTemplate = false

    // MenuBarExtra uses the NSImage's logical size, so set it before handing the
    // image to SwiftUI instead of relying only on a resizable frame.
    private static let original = load(isTemplate: false)
    private static let template = load(isTemplate: true)

    var body: some View {
        Image(nsImage: isTemplate ? Self.template : Self.original)
            .renderingMode(isTemplate ? .template : .original)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    private static func load(isTemplate: Bool) -> NSImage {
        // Copy the named image so the template flag never changes the color asset.
        let image = (NSImage(named: "VeyraMark")?.copy() as? NSImage)
            ?? NSImage(size: NSSize(width: 18, height: 18))
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = isTemplate
        return image
    }
}

/// Typography rendered from the supplied SVG, tinted for the current appearance.
struct VeyraWordmark: View {
    private static let image: NSImage = {
        let image = (NSImage(named: "VeyraWordmark")?.copy() as? NSImage)
            ?? NSImage(size: NSSize(width: 72, height: 29))
        image.size = NSSize(width: 72, height: 29)
        image.isTemplate = true
        return image
    }()

    var body: some View {
        Image(nsImage: Self.image)
            .renderingMode(.template)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: 72, height: 29)
            .accessibilityLabel("Veyra")
    }
}
