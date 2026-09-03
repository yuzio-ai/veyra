import AppKit
import SwiftUI

@main
struct VeyraApp: App {
    @NSApplicationDelegateAdaptor(MonitorAppDelegate.self) private var delegate
    @State private var store = MonitorStore.shared

    var body: some Scene {
        MenuBarExtra {
            MonitorPanel(store: store,
                         initiallyExpandedTaskIDs: PreviewSupport.expandedTaskIDs(for: PreviewSupport.menuScenario),
                         initiallyShowUnknown: PreviewSupport.menuScenario == .unknown)
                .environment(\.monitorReferenceDate, PreviewSupport.menuScenario == nil ? nil : PreviewSupport.referenceDate)
                .environment(\.monitorOpaquePreview, PreviewSupport.menuReduceTransparency)
                .environment(\.monitorPreviewContrast, PreviewSupport.menuIncreasedContrast ? .increased : nil)
        } label: {
            HStack(spacing: 4) {
                VeyraIcon(isTemplate: true)
                Text(store.menuLabel).monospacedDigit()
            }
            .accessibilityLabel("Veyra，\(store.menuLabel.contains("~") ? "本地额度快照，" : "")\(store.menuLabel)")
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
        if let scenario = PreviewSupport.menuScenario {
            if let appearance = PreviewSupport.menuAppearance { NSApp.appearance = NSAppearance(named: appearance) }
            PreviewSupport.configure(MonitorStore.shared, scenario: scenario)
        } else {
            MonitorStore.shared.start()
            let center = NSWorkspace.shared.notificationCenter
            center.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
            center.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        }
        if let index = arguments.firstIndex(of: "--capture-menu-to"), arguments.indices.contains(index + 1) {
            Diagnostics.captureNextMenu(to: URL(fileURLWithPath: arguments[index + 1]))
        }
        if PreviewSupport.menuScenario != nil,
           let index = arguments.firstIndex(of: "--exercise-menu-to"), arguments.indices.contains(index + 1) {
            Diagnostics.exerciseNextMenu(to: URL(fileURLWithPath: arguments[index + 1]))
        }
        // Developer smoke-test entry point; shows the exact menu content using live data.
        if arguments.contains("--show-panel") {
            let view = NSHostingView(rootView: MonitorPanel(store: MonitorStore.shared))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: PanelSizing.width, height: 1),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Veyra"
            window.contentView = view
            view.sizingOptions = [.intrinsicContentSize, .minSize, .maxSize]
            window.setContentSize(view.fittingSize)
            window.center(); window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            previewWindow = window
        }
    }
    @objc private func willSleep(_ notification: Notification) { MonitorStore.shared.sleep() }
    @objc private func didWake(_ notification: Notification) { MonitorStore.shared.wake() }
    func applicationWillTerminate(_ notification: Notification) {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        MonitorStore.shared.stop()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
