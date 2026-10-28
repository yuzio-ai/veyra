import AppKit
import SwiftUI

/// Veyra's supplied brand mark, with a template variant for the system menu bar.
struct VeyraIcon: View {
    var size: CGFloat = 18
    var isTemplate = false

    // The menu bar uses the NSImage's logical size, so set it before handing the
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
    var width: CGFloat = 72
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
            .frame(width: width, height: width * 29 / 72)
            .accessibilityLabel("Veyra")
    }
}

/// Provider identity is supplied by configuration, never inferred from a model or URL.
struct ProviderIcon: View {
    let identity: CodexProviderIdentity
    var size: CGFloat = 16

    private static let marks: [ProviderMark: NSImage] = {
        var images: [ProviderMark: NSImage] = [:]
        for mark in ProviderMark.allCases {
            guard let url = Bundle.main.url(forResource: mark.assetName, withExtension: "png"),
                  let image = NSImage(contentsOf: url) else { continue }
            image.size = NSSize(width: 64, height: 64)
            image.isTemplate = mark.isTemplate
            images[mark] = image
        }
        return images
    }()

    /// Native menus consume an NSImage rather than arbitrary SwiftUI icon content.
    static func menuImage(for identity: CodexProviderIdentity) -> NSImage {
        if let mark = ProviderMark.resolve(identity), let image = marks[mark]?.copy() as? NSImage {
            image.size = NSSize(width: 16, height: 16)
            image.isTemplate = mark.isTemplate
            return image
        }
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            NSColor.labelColor.withAlphaComponent(0.12).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
            if let initial = identity.initial {
                let text = initial as NSString
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 10, weight: .semibold), .foregroundColor: NSColor.labelColor
                ]
                let size = text.size(withAttributes: attributes)
                text.draw(at: NSPoint(x: (16 - size.width) / 2, y: (16 - size.height) / 2), withAttributes: attributes)
            } else {
                NSImage(systemSymbolName: "server.rack", accessibilityDescription: nil)?.draw(in: rect.insetBy(dx: 2, dy: 2))
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    var body: some View {
        Group {
            if let mark = ProviderMark.resolve(identity), let image = Self.marks[mark] {
                Image(nsImage: image).renderingMode(mark.isTemplate ? .template : .original)
                    .resizable().interpolation(.high).scaledToFit()
                    .padding(size * 0.04)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: size * 0.25).fill(.quaternary)
                    if let initial = identity.initial {
                        Text(initial).font(.system(size: size * 0.65, weight: .semibold))
                    } else {
                        Image(systemName: "server.rack").font(.system(size: size * 0.65))
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
