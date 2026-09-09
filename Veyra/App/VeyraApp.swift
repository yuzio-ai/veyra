import AppKit
import SwiftUI

@main
@MainActor
enum VeyraApp {
    static func main() {
        let application = NSApplication.shared
        let delegate = MonitorAppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor
final class MonitorAppDelegate: NSObject, NSApplicationDelegate {
    private var previewWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var menuBar: MenuBarController?
    private lazy var shortcuts = ShortcutStore(registrar: CarbonHotKeyRegistrar(), defaults: allowsGlobalShortcut ? .standard : nil)
    private var allowsGlobalShortcut: Bool {
        let isolatedModes = ["--diagnose", "--render-previews", "--preview-menu", "--show-panel",
                             "--capture-menu-to", "--exercise-menu-to"]
        return !CommandLine.arguments.contains(where: { isolatedModes.contains($0) })
            && ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
    }
    let updates: UpdateStore = {
        let arguments = CommandLine.arguments
        if let scenario = PreviewSupport.menuScenario {
            return UpdateStore.preview(scenario == .updateAvailable ? .available : .idle)
        }
        if arguments.contains("--diagnose") || arguments.contains("--render-previews") || arguments.contains("--preview-menu") {
            return UpdateStore()
        }
        return UpdateStore(defaults: .standard, networkEnabled: true)
    }()

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
            Task { await updates.checkAutomatically() }
            let center = NSWorkspace.shared.notificationCenter
            center.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
            center.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        }
        configureMainMenu()
        menuBar = MenuBarController(store: MonitorStore.shared, updates: updates, openSettings: { [weak self] in
            self?.showSettings()
        })
        shortcuts.onTrigger = { [weak self] in self?.menuBar?.toggle() }
        if allowsGlobalShortcut { shortcuts.start() }
        if arguments.contains("--show-menu") {
            // Finish AppKit launch and attach the status button before the opt-in smoke test opens it.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(250))
                self?.menuBar?.show()
            }
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
            let view = NSHostingView(rootView: MonitorPanel(store: MonitorStore.shared, updates: updates, openSettings: { [weak self] in self?.showSettings() }))
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
    @objc private func showSettings() {
        menuBar?.hide(restoringFocus: false)
        if settingsWindow == nil {
            let hosting = NSHostingView(rootView: MonitorSettings(store: MonitorStore.shared, updates: updates, shortcuts: shortcuts))
            hosting.sizingOptions = [.intrinsicContentSize, .minSize, .maxSize]
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = L10n.text("Settings")
            window.identifier = NSUserInterfaceItemIdentifier("veyra.settings")
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            window.setContentSize(hosting.fittingSize)
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func configureMainMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let settings = appMenu.addItem(withTitle: L10n.text("Settings"), action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L10n.text("Quit Veyra"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)
        let editItem = NSMenuItem()
        editItem.title = L10n.text("Edit")
        let editMenu = NSMenu(title: editItem.title)
        editMenu.addItem(withTitle: L10n.text("Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: L10n.text("Redo"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: L10n.text("Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: L10n.text("Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: L10n.text("Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: L10n.text("Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        menu.addItem(editItem)
        NSApp.mainMenu = menu
    }

    @objc private func willSleep(_ notification: Notification) {
        menuBar?.hide(restoringFocus: false)
        shortcuts.stop()
        MonitorStore.shared.sleep()
    }
    @objc private func didWake(_ notification: Notification) {
        MonitorStore.shared.wake()
        if allowsGlobalShortcut { shortcuts.start() }
    }
    func applicationWillTerminate(_ notification: Notification) {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        shortcuts.stop()
        menuBar?.stop()
        MonitorStore.shared.stop()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
