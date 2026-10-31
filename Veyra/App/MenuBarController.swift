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
    private var renderedQuotaReliable: Bool?
    private let appearanceObserver = StatusItemAppearanceObserver(frame: .zero)

    init(store: MonitorStore, updates: UpdateStore, openSettings: @escaping () -> Void) {
        self.store = store
        super.init()
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        // NSPopover defaults to VibrantLight instead of inheriting NSApp's
        // appearance. Explicit fixtures must apply their appearance here.
        if let appearance = PreviewSupport.menuAppearance {
            popover.appearance = NSAppearance(named: appearance)
        }
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
            })
            .environment(\.monitorReferenceDate, PreviewSupport.menuScenario == nil ? nil : PreviewSupport.referenceDate)
            .environment(\.monitorOpaquePreview, PreviewSupport.menuReduceTransparency)
            .environment(\.monitorPreviewContrast, PreviewSupport.menuIncreasedContrast ? .increased : nil)
            .onExitCommand { [weak self] in self?.hide() }
        let hosting = MonitorPopoverHostingController(rootView: panel)
        hosting.onDismiss = { [weak self] in self?.hide() }
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
            // Keep the native highlighted image, including during mouse tracking.
            (button.cell as? NSButtonCell)?.highlightsBy.insert(.contentsCellMask)
            appearanceObserver.onChange = { [weak self] in self?.updateStatusImage(force: true) }
            button.addSubview(appearanceObserver)
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(displayOptionsChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
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
            if let appearance = PreviewSupport.menuAppearance {
                window.appearance = NSAppearance(named: appearance)
            }
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
        updateStatusImage(force: true)
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
        updateStatusImage(force: true)
        previousApplication = nil
        store.setPanelVisible(false)
    }

    func stop() {
        stopped = true
        hide(restoringFocus: false)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        appearanceObserver.onChange = nil
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    @objc private func displayOptionsChanged() { updateStatusImage(force: true) }

    private func updateStatusImage(force: Bool = false) {
        guard !stopped, let button = statusItem.button else { return }
        let percent = store.menuQuotaPercent, showsQuota = store.showsQuota, taskCount = store.menuTaskCount
        let reliable = store.quota.error == nil
        guard force || renderedQuota != percent || renderedShowsQuota != showsQuota
            || renderedTaskCount != taskCount || renderedQuotaReliable != reliable else { return }
        button.image = Self.statusImage(percent: percent, showsQuota: showsQuota, taskCount: taskCount,
            quotaReliable: reliable, appearance: button.effectiveAppearance, highlighted: popover.isShown)
        button.alternateImage = Self.statusImage(percent: percent, showsQuota: showsQuota, taskCount: taskCount,
            highlighted: true)
        renderedQuota = percent; renderedShowsQuota = showsQuota; renderedTaskCount = taskCount
        renderedQuotaReliable = reliable
    }

    private func updateLabel() {
        guard !stopped else { return }
        withObservationTracking {
            updateStatusImage()
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
    static func statusImage(percent: Double?, showsQuota: Bool, taskCount: String,
                            quotaReliable: Bool = true, appearance: NSAppearance? = nil,
                            highlighted: Bool = false, increasedContrast: Bool? = nil) -> NSImage {
        let imageHeight: CGFloat = 22
        let shapeHeight: CGFloat = 20
        let strokeWidth: CGFloat = 1.5
        let shapeInset = (imageHeight - shapeHeight) / 2
        let center = imageHeight / 2
        let value = percent.flatMap { $0.isFinite ? min(100, max(0, $0)) : nil }
        let accent: NSColor? = showsQuota && quotaReliable && !highlighted
            ? value.flatMap { $0 < 10 ? .systemRed : ($0 < 30 ? .systemOrange : nil) } : nil
        let drawingAppearance = appearance ?? NSAppearance.currentDrawing()
        // Resolve against the status button's appearance, which can differ from
        // the app's appearance when the menu bar follows a different wallpaper.
        var foreground = NSColor.black
        var resolvedAccent = accent
        drawingAppearance.performAsCurrentDrawingAppearance {
            if accent != nil {
                foreground = (NSColor.labelColor.usingColorSpace(.deviceRGB) ?? .labelColor).withAlphaComponent(1)
            }
            resolvedAccent = accent?.usingColorSpace(.deviceRGB)
        }
        let label = DisplayFormat.percent(value).replacingOccurrences(of: "%", with: "")
        let taskText = taskCount as NSString
        let taskAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium), .foregroundColor: foreground
        ]
        let taskSize = taskText.size(withAttributes: taskAttributes)
        let badgeWidth = max(imageHeight, ceil(taskSize.width) + 12)
        let badgeX: CGFloat = showsQuota ? 28 : 0
        let appearanceName = drawingAppearance.bestMatch(from: [.accessibilityHighContrastAqua,
            .accessibilityHighContrastDarkAqua, .aqua, .darkAqua])
        let highContrast = increasedContrast ?? (NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            || appearanceName == .accessibilityHighContrastAqua || appearanceName == .accessibilityHighContrastDarkAqua)
        let image = NSImage(size: NSSize(width: badgeX + badgeWidth, height: imageHeight), flipped: false) { _ in
            if showsQuota {
                let rect = NSRect(x: shapeInset, y: shapeInset, width: shapeHeight, height: shapeHeight)
                foreground.withAlphaComponent(highContrast ? 0.5 : 0.25).setStroke()
                let track = NSBezierPath(ovalIn: rect)
                track.lineWidth = strokeWidth; track.stroke()
                if let value, value > 0 {
                    (resolvedAccent ?? foreground).setStroke()
                    let arc = NSBezierPath()
                    arc.lineWidth = strokeWidth; arc.lineCapStyle = .round
                    arc.appendArc(withCenter: NSPoint(x: center, y: center), radius: shapeHeight / 2,
                                  startAngle: 90, endAngle: 90 - 360 * value / 100, clockwise: true)
                    arc.stroke()
                }
                let text = label as NSString
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: label.count > 2 ? 9 : 10.5, weight: .semibold),
                    .foregroundColor: value == 0 ? (resolvedAccent ?? foreground) : foreground
                ]
                let size = text.size(withAttributes: attributes)
                text.draw(at: NSPoint(x: center - size.width / 2, y: center - size.height / 2), withAttributes: attributes)
            }
            let badge = NSBezierPath(roundedRect: NSRect(x: badgeX + shapeInset, y: shapeInset,
                                                       width: badgeWidth - 2 * shapeInset, height: shapeHeight),
                                     xRadius: 5, yRadius: 5)
            foreground.setStroke()
            badge.lineWidth = strokeWidth; badge.stroke()
            taskText.draw(at: NSPoint(x: badgeX + (badgeWidth - taskSize.width) / 2, y: center - taskSize.height / 2),
                          withAttributes: taskAttributes)
            return true
        }
        image.isTemplate = accent == nil
        return image
    }
}

/// Observes the actual menu bar appearance without replacing its native button.
@MainActor
private final class StatusItemAppearanceObserver: NSView {
    var onChange: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onChange?()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
private final class MonitorPopoverHostingController<Content: View>: NSHostingController<Content>, MonitorMenuDismissalHandling {
    var onDismiss: (() -> Void)?

    func dismissMenu() { onDismiss?() }
    override func cancelOperation(_ sender: Any?) { dismissMenu() }
}
