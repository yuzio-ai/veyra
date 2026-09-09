import AppKit
import SwiftUI
import Observation

/// Owns one status item and one native popover for both mouse and keyboard actions.
@MainActor
final class MenuBarController: NSObject, NSPopoverDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let store: MonitorStore
    private var previousApplication: NSRunningApplication?
    private var stopped = false

    init(store: MonitorStore, updates: UpdateStore, openSettings: @escaping () -> Void) {
        self.store = store
        super.init()
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        let panel = MonitorPanel(store: store, updates: updates,
            initiallyExpandedTaskIDs: PreviewSupport.expandedTaskIDs(for: PreviewSupport.menuScenario),
            initiallyShowUnknown: PreviewSupport.menuScenario == .unknown,
            onSizingChange: { [weak self] sizing in
                guard let self else { return }
                let size = NSSize(width: PanelSizing.width, height: max(1, sizing.panelHeight))
                if self.popover.contentSize != size { self.popover.contentSize = size }
            }, openSettings: { [weak self] in
                self?.hide(restoringFocus: false)
                openSettings()
            })
            .environment(\.monitorReferenceDate, PreviewSupport.menuScenario == nil ? nil : PreviewSupport.referenceDate)
            .environment(\.monitorOpaquePreview, PreviewSupport.menuReduceTransparency)
            .environment(\.monitorPreviewContrast, PreviewSupport.menuIncreasedContrast ? .increased : nil)
            .onExitCommand { [weak self] in self?.hide() }
        let hosting = NSHostingController(rootView: panel)
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        Diagnostics.menuWindow = { [weak self] in self?.popover.contentViewController?.view.window }
        Diagnostics.toggleMenu = { [weak self] in self?.toggle() }
        popover.contentSize = NSSize(width: PanelSizing.width, height: 1)
        if let button = statusItem.button {
            let image = (NSImage(named: "VeyraMark")?.copy() as? NSImage) ?? NSImage(size: NSSize(width: 18, height: 18))
            image.size = NSSize(width: 18, height: 18)
            image.isTemplate = true
            button.image = image
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(toggle)
            button.setAccessibilityIdentifier("monitor.statusItem")
        }
        updateLabel()
    }

    @objc func toggle() {
        if popover.isShown { hide() } else { show() }
    }

    func show() {
        guard !stopped, !popover.isShown, let button = statusItem.button else { return }
        let frontmost = NSWorkspace.shared.frontmostApplication
        previousApplication = frontmost?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : frontmost
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // Native transient popovers accept keyboard focus without activating the app
        // or switching away from another application's full-screen Space.
        popover.contentViewController?.view.window?.makeKey()
        button.highlight(true)
    }

    func hide(restoringFocus: Bool = true) {
        guard popover.isShown else { return }
        let previous = previousApplication
        previousApplication = nil
        let shouldRestore = restoringFocus && popover.contentViewController?.view.window?.isKeyWindow == true
        popover.performClose(nil)
        if shouldRestore, let previous, !previous.isTerminated,
           NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            previous.activate(options: [])
        }
    }

    func popoverDidClose(_ notification: Notification) {
        statusItem.button?.highlight(false)
        previousApplication = nil
        store.setPanelVisible(false)
    }

    func stop() {
        stopped = true
        hide(restoringFocus: false)
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    private func updateLabel() {
        guard !stopped else { return }
        withObservationTracking {
            statusItem.button?.attributedTitle = NSAttributedString(string: " " + store.menuLabel,
                attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)])
            statusItem.button?.setAccessibilityLabel(store.menuAccessibilityLabel)
        } onChange: { [weak self] in
            Task { @MainActor in self?.updateLabel() }
        }
    }
}
