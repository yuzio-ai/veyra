import AppKit
import SwiftUI

private struct OpaquePreviewKey: EnvironmentKey {
    static let defaultValue = false
}

private struct MonitorReferenceDateKey: EnvironmentKey {
    static let defaultValue: Date? = nil
}

private struct MonitorPreviewContrastKey: EnvironmentKey {
    static let defaultValue: ColorSchemeContrast? = nil
}

extension EnvironmentValues {
    /// Developer-only layout rendering; never changes the system setting.
    var monitorOpaquePreview: Bool {
        get { self[OpaquePreviewKey.self] }
        set { self[OpaquePreviewKey.self] = newValue }
    }

    /// Freeze timestamps in explicit developer fixtures, never in the live monitor.
    var monitorReferenceDate: Date? {
        get { self[MonitorReferenceDateKey.self] }
        set { self[MonitorReferenceDateKey.self] = newValue }
    }

    /// A fixture input: the real accessibility contrast environment is read-only.
    var monitorPreviewContrast: ColorSchemeContrast? {
        get { self[MonitorPreviewContrastKey.self] }
        set { self[MonitorPreviewContrastKey.self] = newValue }
    }
}

/// Only group fixed controls. Never wrap a scrolling content area in this container.
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
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.monitorPreviewContrast) private var previewContrast
    @Environment(\.monitorOpaquePreview) private var opaquePreview

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        let increasedContrast = (previewContrast ?? contrast) == .increased
        content
            .background {
                if reduceTransparency || opaquePreview {
                    shape.fill(Color(nsColor: .controlBackgroundColor))
                } else {
                    // The system owns the popover material; scrolling cards use
                    // vibrant fill and a semantic separator, never another glass layer.
                    shape.fill(.quaternary)
                }
            }
            .overlay {
                shape.strokeBorder(increasedContrast ? Color.primary : Color(nsColor: .separatorColor),
                                   lineWidth: increasedContrast ? 1 : 1 / max(1, displayScale))
                    .allowsHitTesting(false)
            }
    }
}

struct MonitorActionStyle: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.monitorOpaquePreview) private var opaquePreview

    func body(content: Content) -> some View {
        if #available(macOS 26, *), !reduceTransparency && !opaquePreview {
            content.buttonStyle(.glass).buttonBorderShape(.circle).controlSize(.regular)
        } else {
            content.buttonStyle(.bordered).buttonBorderShape(.circle).controlSize(.regular)
        }
    }
}
