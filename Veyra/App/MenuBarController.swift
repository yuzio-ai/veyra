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
    private var renderedQuota: Double?
    private var renderedShowsQuota: Bool?
    private var renderedTaskCount: String?

    init(store: MonitorStore, updates: UpdateStore, openSettings: @escaping () -> Void,
         profiles: CodexModelProfilesStore? = nil, openModelProfiles: @escaping () -> Void = {}) {
        self.store = store
        super.init()
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        let panel = MonitorPanel(store: store, updates: updates,
            initiallyExpandedTaskIDs: PreviewSupport.expandedTaskIDs(for: PreviewSupport.menuScenario),
            initiallyShowUnknown: PreviewSupport.menuScenario == .unknown || PreviewSupport.menuScenario == .dshUnknown,
            onSizingChange: { [weak self] sizing in
                guard let self else { return }
                let size = NSSize(width: PanelSizing.width, height: max(1, sizing.panelHeight))
                if self.popover.contentSize != size { self.popover.contentSize = size }
            }, openSettings: { [weak self] in
                self?.hide(restoringFocus: false)
                openSettings()
            }, profiles: profiles, openModelProfiles: { [weak self] in
                self?.hide(restoringFocus: false)
                openModelProfiles()
            }, closeMenu: { [weak self] in self?.hide() })
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
            button.imagePosition = .imageOnly
            button.title = ""
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
        if let window = popover.contentViewController?.view.window {
            // Keep this popover in the current Space before activating. An
            // inactive accessory app's makeKey() alone cannot receive Escape.
            if !window.collectionBehavior.contains(.canJoinAllSpaces) {
                window.collectionBehavior.insert(.moveToActiveSpace)
            }
            window.collectionBehavior.insert(.fullScreenAuxiliary)
            window.makeKey()
            NSApp.activate()
        }
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
            NSApp.yieldActivation(to: previous)
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
            let percent = store.menuQuotaPercent, showsQuota = store.showsQuota, taskCount = store.menuTaskCount
            if renderedQuota != percent || renderedShowsQuota != showsQuota || renderedTaskCount != taskCount {
                statusItem.button?.image = Self.statusImage(percent: percent, showsQuota: showsQuota, taskCount: taskCount)
                renderedQuota = percent; renderedShowsQuota = showsQuota; renderedTaskCount = taskCount
            }
            // Preserve AppKit's hover tracking when monitoring updates leave the text unchanged.
            let tooltip = store.menuLabel
            if statusItem.button?.toolTip != tooltip {
                statusItem.button?.toolTip = tooltip
            }
            statusItem.button?.setAccessibilityLabel(store.menuAccessibilityLabel)
        } onChange: { [weak self] in
            Task { @MainActor in self?.updateLabel() }
        }
    }

    /// One image captures one value, so the ring and its label always change together.
    static func statusImage(percent: Double?, showsQuota: Bool, taskCount: String) -> NSImage {
        let imageHeight: CGFloat = 22
        let shapeHeight: CGFloat = 20
        let strokeWidth: CGFloat = 1.5
        let shapeInset = (imageHeight - shapeHeight) / 2
        let center = imageHeight / 2
        let value = percent.map { min(100, max(0, $0)) }
        let label = DisplayFormat.percent(value).replacingOccurrences(of: "%", with: "")
        let taskText = taskCount as NSString
        let taskAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.black
        ]
        let taskSize = taskText.size(withAttributes: taskAttributes)
        let badgeWidth = max(imageHeight, ceil(taskSize.width) + 12)
        let badgeX: CGFloat = showsQuota ? 28 : 0
        let image = NSImage(size: NSSize(width: badgeX + badgeWidth, height: imageHeight), flipped: false) { _ in
            if showsQuota {
                let rect = NSRect(x: shapeInset, y: shapeInset, width: shapeHeight, height: shapeHeight)
                NSColor.black.withAlphaComponent(0.25).setStroke()
                let track = NSBezierPath(ovalIn: rect)
                track.lineWidth = strokeWidth; track.stroke()
                if let value, value > 0 {
                    NSColor.black.setStroke()
                    let arc = NSBezierPath()
                    arc.lineWidth = strokeWidth; arc.lineCapStyle = .round
                    arc.appendArc(withCenter: NSPoint(x: center, y: center), radius: shapeHeight / 2,
                                  startAngle: 90, endAngle: 90 - 360 * value / 100, clockwise: true)
                    arc.stroke()
                }
                let text = label as NSString
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: label.count > 2 ? 9 : 10.5, weight: .semibold),
                    .foregroundColor: NSColor.black
                ]
                let size = text.size(withAttributes: attributes)
                text.draw(at: NSPoint(x: center - size.width / 2, y: center - size.height / 2), withAttributes: attributes)
            }
            let badge = NSBezierPath(roundedRect: NSRect(x: badgeX + shapeInset, y: shapeInset,
                                                       width: badgeWidth - 2 * shapeInset, height: shapeHeight),
                                     xRadius: 5, yRadius: 5)
            NSColor.black.setStroke()
            badge.lineWidth = strokeWidth; badge.stroke()
            taskText.draw(at: NSPoint(x: badgeX + (badgeWidth - taskSize.width) / 2, y: center - taskSize.height / 2),
                          withAttributes: taskAttributes)
            return true
        }
        image.isTemplate = true
        return image
    }
}
