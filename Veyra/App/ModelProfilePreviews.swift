import AppKit
import SwiftUI

/// Fixed local fixtures only. No real Codex configuration is opened by this renderer.
@MainActor
enum ModelProfilePreviews {
    static func render(to directory: URL) async throws -> [[String: Any]] {
        try await ModelProfileWindowChecks.run(to: directory)
        var results: [[String: Any]] = []
        let styles: [(String, NSAppearance.Name, Bool)] = [
            ("light", .aqua, false), ("dark", .darkAqua, false),
            ("light-increased", .accessibilityHighContrastAqua, false),
            ("dark-increased", .accessibilityHighContrastDarkAqua, false),
            ("light-opaque", .aqua, true), ("dark-opaque", .darkAqua, true)
        ]
        for scenario in ["general", "normal", "empty", "invalid", "error", "long", "success", "preset-empty", "preset-configured", "preset-current", "preset-error", "preset-unsupported", "preset-busy", "preset-dirty", "preset-loading", "preset-no-models", "preset-cached", "preset-auth", "preset-removed", "preset-capabilities-missing", "preset-repair", "workspace-create", "workspace-local", "workspace-tested", "workspace-protocol", "workspace-small", "workspace-expanded"] {
            for (style, appearance, opaque) in styles {
                let profiles = CodexModelProfilesStore.preview(scenario)
                if scenario == "general" { profiles.tab = .general }
                let monitor = PreviewSupport.settingsStore(.automatic)
                let width: CGFloat = scenario == "workspace-small" ? 900 : 1100
                let height: CGFloat = scenario == "workspace-small" ? 600 : 780
                let view = MonitorSettings(store: monitor, updates: .preview(.idle), profiles: profiles)
                    .environment(\.monitorOpaquePreview, opaque)
                    .background(Color(nsColor: .windowBackgroundColor))
                let host = NSHostingView(rootView: view)
                let window = SettingsWindow.make(hosting: host, contentSize: NSSize(width: width, height: height))
                window.appearance = NSAppearance(named: appearance)
                let toolbar = SettingsToolbarController(profiles: profiles, window: window)
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                window.makeFirstResponder(nil)
                try await Task.sleep(for: .milliseconds(100))
                host.layoutSubtreeIfNeeded()
                let name = "models-\(scenario)-\(style)"
                // Include the native titlebar and toolbar, which a content-only bitmap omits.
                guard let frame = host.superview else {
                    throw NSError(domain: "SettingsToolbarPreview", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "Native window frame is missing"])
                }
                frame.layoutSubtreeIfNeeded()
                try PreviewSupport.saveBitmap(frame, to: directory.appendingPathComponent(name + ".png"))
                results.append(["name": name, "width": frame.bounds.width, "height": frame.bounds.height,
                                "evidence": "native-window-view-bitmap", "reduceTransparency": opaque])
                window.close()
                withExtendedLifetime(toolbar) {}
            }
        }
        for scenario in ["preset-empty", "preset-configured", "preset-current", "preset-error", "preset-repair", "normal", "empty", "provider-custom", "provider-long", "provider-busy", "provider-unavailable", "error", "success", "provider-overridden"] {
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
        return results
    }
}
