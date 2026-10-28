import AppKit
import SwiftUI

/// Fixed local fixtures only. No real Codex configuration is opened by this renderer.
@MainActor
enum ModelProfilePreviews {
    static func render(to directory: URL) async throws -> [[String: Any]] {
        var results: [[String: Any]] = []
        let styles: [(String, NSAppearance.Name, Bool)] = [
            ("light", .aqua, false), ("dark", .darkAqua, false),
            ("light-increased", .accessibilityHighContrastAqua, false),
            ("dark-increased", .accessibilityHighContrastDarkAqua, false),
            ("light-opaque", .aqua, true), ("dark-opaque", .darkAqua, true)
        ]
        for scenario in ["normal", "empty", "invalid", "error", "long", "success", "undo", "preset-empty", "preset-configured", "preset-current", "preset-error", "preset-unsupported", "preset-busy", "preset-dirty", "preset-loading", "preset-no-models", "preset-cached", "preset-auth", "preset-removed", "preset-capabilities-missing", "preset-repair", "workspace-create", "workspace-local", "workspace-tested", "workspace-protocol", "workspace-small", "workspace-expanded"] {
            for (style, appearance, opaque) in styles {
                let profiles = CodexModelProfilesStore.preview(scenario)
                let home = URL(fileURLWithPath: "/tmp/veyra-model-profile-preview")
                let monitor = MonitorStore(inspectConfiguration: { _, _ in
                    CodexConfigurationReport(location: CodexLocation(home: home, executable: nil), state: .notFound)
                })
                monitor.isPreview = true
                let width: CGFloat = scenario == "workspace-small" ? 900 : 1100
                let height: CGFloat = scenario == "workspace-small" ? 630 : 780
                let view = MonitorSettings(store: monitor, updates: .preview(.idle), profiles: profiles)
                    .frame(width: width, height: height)
                    .environment(\.monitorOpaquePreview, opaque)
                    .background(Color(nsColor: .windowBackgroundColor))
                let host = NSHostingView(rootView: view)
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: appearance)
                window.contentView = host
                window.orderFront(nil)
                try await Task.sleep(for: .milliseconds(100))
                host.layoutSubtreeIfNeeded()
                let name = "models-\(scenario)-\(style)"
                try PreviewSupport.saveBitmap(host, to: directory.appendingPathComponent(name + ".png"))
                results.append(["name": name, "width": host.bounds.width, "height": host.bounds.height,
                                "evidence": "layout-preview", "reduceTransparency": opaque])
                window.close()
            }
        }
        for scenario in ["preset-empty", "preset-configured", "preset-current", "preset-error", "preset-repair", "normal", "empty", "undo", "provider-custom", "provider-long", "provider-busy", "provider-unavailable", "error", "success", "provider-overridden"] {
            for (style, appearance, _) in styles {
                let profiles = CodexModelProfilesStore.preview(scenario)
                let monitor = MonitorStore()
                PreviewSupport.configure(monitor, scenario: .single)
                let host = NSHostingView(rootView: MonitorPanel(store: monitor, profiles: profiles)
                    .environment(\.monitorReferenceDate, PreviewSupport.referenceDate)
                    // Bitmaps cannot capture native vibrancy. The actual popover is checked separately.
                    .environment(\.monitorOpaquePreview, true)
                    .environment(\.monitorPreviewContrast, style.contains("increased") ? .increased : .standard)
                    .background(Color(nsColor: .windowBackgroundColor)))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: PanelSizing.width, height: 1),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: appearance)
                window.contentView = host
                window.orderFront(nil)
                for _ in 0..<3 {
                    try await Task.sleep(for: .milliseconds(70))
                    host.layoutSubtreeIfNeeded()
                    window.setContentSize(host.fittingSize)
                }
                // Catch labels whose intrinsic image sizing silently expands the fixed header.
                guard abs(host.bounds.width - PanelSizing.width) < 1, host.bounds.height < 800 else {
                    throw NSError(domain: "ProviderQuickSwitchPreview", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "Unexpected provider menu size: \(host.bounds.size)"])
                }
                try ModelProfileWindowChecks.checkQuickSwitchLayout(host, profiles: profiles)
                let name = scenario == "normal" ? "models-quick-switch-\(style)" : "models-quick-switch-\(scenario)-\(style)"
                try PreviewSupport.saveBitmap(host, to: directory.appendingPathComponent(name + ".png"))
                results.append(["name": name, "width": host.bounds.width, "height": host.bounds.height,
                                "evidence": "layout-preview", "reduceTransparency": true])
                window.close()
            }
        }
        try await ModelProfileWindowChecks.run(to: directory)
        return results
    }
}
