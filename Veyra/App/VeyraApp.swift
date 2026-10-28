import AppKit
import SwiftUI

@main
@MainActor
enum VeyraApp {
    static func main() {
        if let result = ProviderCredentialCommand.run(Array(CommandLine.arguments.dropFirst())) { exit(result) }
        let application = NSApplication.shared
        let delegate = MonitorAppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor
final class MonitorAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var previewWindow: NSWindow?
    private var settingsToolbar: SettingsToolbarController?
    private var settingsWindow: NSWindow?
    private var dashboardWindow: NSWindow?
    private lazy var dashboard = DashboardStore()
    private lazy var modelProfiles = PreviewSupport.menuScenario == nil ? CodexModelProfilesStore() : CodexModelProfilesStore.preview()
    private var modelSettingsDelegate: ModelProfileSettingsWindowDelegate?
    private var menuBar: MenuBarController?
    private lazy var shortcuts = ShortcutStore(registrar: CarbonHotKeyRegistrar(), defaults: allowsGlobalShortcut ? .standard : nil)
    private var allowsGlobalShortcut: Bool {
        let isolatedModes = ["--diagnose", "--render-previews", "--render-dashboard-previews", "--preview-menu", "--show-panel",
                             "--capture-menu-to", "--exercise-menu-to", "--render-provider-previews"]
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
        if let index = arguments.firstIndex(of: "--render-dashboard-previews"), arguments.indices.contains(index + 1) {
            DashboardPreview.render(to: URL(fileURLWithPath: arguments[index + 1]))
            return
        }
        if let index = arguments.firstIndex(of: "--render-previews"), arguments.indices.contains(index + 1) {
            MonitorStore.shared.isPreview = true
            PreviewSupport.render(to: URL(fileURLWithPath: arguments[index + 1]))
            return
        }
        if let index = arguments.firstIndex(of: "--render-provider-previews"), arguments.indices.contains(index + 1) {
            MonitorStore.shared.isPreview = true
            PreviewSupport.renderProviders(to: URL(fileURLWithPath: arguments[index + 1]))
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
        }, openDashboard: { [weak self] in
            self?.showDashboard()
        }, profiles: modelProfiles, openModelProfiles: { [weak self] in
            self?.showModelProfiles()
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
        if arguments.contains("--show-dashboard") {
            // Opt-in live-data smoke test; uses the same window and configured home as the menu action.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(250))
                self?.showDashboard()
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
            let hosting = NSHostingView(rootView: MonitorSettings(store: MonitorStore.shared, updates: updates, shortcuts: shortcuts,
                                                                profiles: modelProfiles))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 780),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = L10n.text("Settings")
            window.identifier = NSUserInterfaceItemIdentifier("veyra.settings")
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            window.minSize = NSSize(width: 900, height: 630)
            settingsToolbar = SettingsToolbarController(profiles: modelProfiles, window: window)
            let delegate = ModelProfileSettingsWindowDelegate(profiles: modelProfiles)
            modelSettingsDelegate = delegate
            window.delegate = delegate
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func showModelProfiles() {
        if modelProfiles.tab != .models { modelProfiles.navigate { self.modelProfiles.tab = .models } }
        showSettings()
    }

    @objc private func showDashboard() {
        menuBar?.hide(restoringFocus: false)
        if dashboardWindow == nil {
            let view = DashboardView(store: dashboard, monitor: MonitorStore.shared)
                .onChange(of: MonitorStore.shared.location.home.path) { [weak self] _, _ in
                    guard let self, self.dashboardWindow?.isVisible == true, !MonitorStore.shared.isPreview else { return }
                    self.dashboard.start(home: MonitorStore.shared.location.home)
                }
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 900),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = L10n.text("Task overview")
            window.identifier = NSUserInterfaceItemIdentifier("veyra.dashboard")
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: view)
            window.minSize = NSSize(width: 900, height: 660)
            if let available = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame {
                window.setContentSize(NSSize(width: min(1280, available.width), height: min(900, available.height - 40)))
            }
            window.delegate = self
            window.center()
            dashboardWindow = window
        }
        if MonitorStore.shared.isPreview {
            dashboard.configurePreview(DashboardPreview.fixture(scenario: "normal"), anchor: DashboardPreview.referenceDate)
        } else {
            dashboard.start(home: MonitorStore.shared.location.home)
        }
        NSApp.activate(ignoringOtherApps: true)
        dashboardWindow?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSWindow) === dashboardWindow { dashboard.stop() }
    }

    private func configureMainMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let statistics = appMenu.addItem(withTitle: L10n.text("Task statistics"), action: #selector(showDashboard), keyEquivalent: "d")
        statistics.target = self
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
        dashboard.stop()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
