import AppKit
import SwiftUI

@main
struct VeyraApp: App {
    @NSApplicationDelegateAdaptor(MonitorAppDelegate.self) private var delegate
    @State private var store = MonitorStore.shared

    var body: some Scene {
        MenuBarExtra {
            MonitorPanel(store: store)
        } label: {
            HStack(spacing: 4) {
                VeyraIcon(isTemplate: true)
                Text(store.menuLabel).monospacedDigit()
            }
            .accessibilityLabel("Veyra，\(store.menuLabel)")
        }
        .menuBarExtraStyle(.window)

        Settings {
            MonitorSettings(store: store)
        }
    }
}

@MainActor
final class MonitorAppDelegate: NSObject, NSApplicationDelegate {
    private var previewWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let arguments = CommandLine.arguments
        if arguments.contains("--diagnose") {
            Diagnostics.run()
            return
        }
        if let index = arguments.firstIndex(of: "--render-previews"), arguments.indices.contains(index + 1) {
            MonitorStore.shared.isPreview = true
            PreviewSupport.render(to: URL(fileURLWithPath: arguments[index + 1]))
            return
        }
        MonitorStore.shared.start()
        if let index = arguments.firstIndex(of: "--capture-menu-to"), arguments.indices.contains(index + 1) {
            Diagnostics.captureNextMenu(to: URL(fileURLWithPath: arguments[index + 1]))
        }
        // Developer smoke-test entry point; shows the exact menu content using live data.
        if arguments.contains("--show-panel") {
            let view = NSHostingView(rootView: MonitorPanel(store: MonitorStore.shared))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 660),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Veyra"
            window.contentView = view
            window.center(); window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            previewWindow = window
        }
    }
    func applicationWillTerminate(_ notification: Notification) { MonitorStore.shared.stop() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
