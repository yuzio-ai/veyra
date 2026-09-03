import AppKit
import SwiftUI

private struct OpaquePreviewKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Developer-only layout rendering; never changes the system setting.
    var monitorOpaquePreview: Bool {
        get { self[OpaquePreviewKey.self] }
        set { self[OpaquePreviewKey.self] = newValue }
    }
}

/// Group the separate control-center surfaces without nesting glass effects.
struct MonitorGlassGroup<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.monitorOpaquePreview) private var opaquePreview

    var body: some View {
        if #available(macOS 26, *), !reduceTransparency && !opaquePreview {
            GlassEffectContainer(spacing: 8) { content() }
        } else {
            content()
        }
    }
}

struct ControlCenterTile: ViewModifier {
    var cornerRadius: CGFloat = 26
    var interactive = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.monitorOpaquePreview) private var opaquePreview

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if reduceTransparency || opaquePreview {
            content.background(Color(nsColor: .controlBackgroundColor), in: shape)
                .overlay(shape.strokeBorder(.primary.opacity(0.1), lineWidth: 0.5))
        } else if #available(macOS 26, *) {
            if interactive {
                content.glassEffect(.regular.interactive(), in: shape)
            } else {
                content.glassEffect(.regular, in: shape)
            }
        } else {
            content.background(.ultraThinMaterial, in: shape)
                .overlay(shape.strokeBorder(.primary.opacity(0.1), lineWidth: 0.5))
        }
    }
}

/// The system samples windows behind the popup; no screenshot or custom blur.
struct MonitorBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> BackdropView {
        let view = BackdropView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: BackdropView, context: Context) {}

    final class BackdropView: NSVisualEffectView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // This view is only installed in our panel, never in the status item
            // or Settings window. Keep the native popup chrome transparent.
            window?.isOpaque = false
            window?.backgroundColor = .clear
            window?.hasShadow = true
            // Inherit system appearance, including automatic light/dark changes.
            window?.appearance = nil
        }
    }
}
