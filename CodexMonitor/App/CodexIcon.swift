import AppKit
import SwiftUI

/// Original Codex artwork bundled with the user's installed desktop app.
struct CodexIcon: View {
    var size: CGFloat = 18

    // MenuBarExtra uses the NSImage's logical size, so set it before handing the
    // image to SwiftUI instead of relying only on a resizable frame.
    private static let light = load("CodexMarkLight")

    var body: some View {
        Image(nsImage: Self.light)
            .renderingMode(.original)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    private static func load(_ name: String) -> NSImage {
        let image = NSImage(named: name) ?? NSImage(size: NSSize(width: 18, height: 18))
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = false
        return image
    }
}
