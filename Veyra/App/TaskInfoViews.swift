import AppKit
import SwiftUI

struct TaskInfoDetail: Equatable {
    let label: String
    let value: String
}

struct TaskInfoContent: Equatable {
    let title: String
    var paragraphs: [String] = []
    var details: [TaskInfoDetail] = []
    var isUpdating = false
}

private struct TaskInfoPresenterKey: EnvironmentKey {
    static let defaultValue: TaskInfoPresenter? = nil
}

extension EnvironmentValues {
    var taskInfoPresenter: TaskInfoPresenter? {
        get { self[TaskInfoPresenterKey.self] }
        set { self[TaskInfoPresenterKey.self] = newValue }
    }
}

/// Owned by one menu, never global. Closing the menu or removing an anchor also
/// closes its explanation; opening another field replaces the previous explanation.
@MainActor
final class TaskInfoPresenter: NSObject, NSPopoverDelegate {
    private var popover: NSPopover?
    private weak var anchor: TaskInfoNativeButton?
    private(set) var content: TaskInfoContent?
    private var openedWithKeyboardFocus = false
    private var keyMonitor: Any?
    private var windowObserver: NSObjectProtocol?
    private(set) var shownIdentifier: String?
    var window: NSWindow? { popover?.contentViewController?.view.window }
    var contentController: NSViewController? { popover?.contentViewController }

    /// Opaque fixture rendering of the same text body; this is layout evidence,
    /// not a screenshot of the compositor's native popover material.
    func saveContentPreview(to destination: URL) throws {
        guard let content else { throw CocoaError(.fileWriteUnknown) }
        let renderer = ImageRenderer(content: TaskInfoBody(content: content).frame(width: 268).padding(16)
            .background(Color(nsColor: .windowBackgroundColor)))
        renderer.scale = 2
        guard let image = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try png.write(to: destination)
    }

    func toggle(from button: TaskInfoNativeButton, identifier: String, content: TaskInfoContent) {
        button.clearTransientHighlight()
        let keyboardOrigin = button.usesKeyboardFocusAppearance
        if anchor === button {
            openedWithKeyboardFocus = keyboardOrigin
            dismiss()
            return
        }
        dismiss(restoringFocus: false)
        guard let sourceWindow = button.window, sourceWindow.isVisible else { return }
        let popover = NSPopover()
        popover.animates = false
        popover.behavior = .semitransient
        popover.appearance = button.effectiveAppearance
        popover.delegate = self
        self.popover = popover; anchor = button; shownIdentifier = identifier
        openedWithKeyboardFocus = keyboardOrigin
        install(content)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxX)
        window?.makeKey()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                guard event.keyCode == 53, let self,
                      event.window === self.window || event.window === self.anchor?.window else { return false }
                self.dismiss()
                return true
            }
            return handled ? nil : event
        }
        windowObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
            object: sourceWindow, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismiss(restoringFocus: false) }
            }
    }

    func update(anchor button: TaskInfoNativeButton, identifier: String, content: TaskInfoContent) {
        guard anchor === button else { return }
        guard shownIdentifier == identifier else { dismiss(restoringFocus: false); return }
        if self.content != content { install(content) }
    }

    func dismiss(ifAnchor button: TaskInfoNativeButton) {
        if anchor === button { dismiss(restoringFocus: false) }
    }

    func dismiss(restoringFocus: Bool = true) {
        guard let previous = popover else { return }
        let button = anchor
        let restoreKeyboardAppearance = openedWithKeyboardFocus
        popover = nil; anchor = nil; content = nil; shownIdentifier = nil
        openedWithKeyboardFocus = false
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        if let windowObserver { NotificationCenter.default.removeObserver(windowObserver); self.windowObserver = nil }
        previous.delegate = nil
        previous.performClose(nil)
        button?.clearTransientHighlight()
        if restoringFocus, let button, let parent = button.window, parent.isVisible, NSApp.isActive {
            parent.makeKey(); parent.makeFirstResponder(button)
            button.setKeyboardFocusAppearance(restoreKeyboardAppearance)
        }
    }

    func popoverDidClose(_ notification: Notification) { dismiss(restoringFocus: false) }

    private func install(_ content: TaskInfoContent) {
        self.content = content
        let available = anchor?.window?.screen?.visibleFrame.height ?? 800
        let controller: TaskInfoHostingController
        if let existing = popover?.contentViewController as? TaskInfoHostingController {
            controller = existing
        } else {
            controller = TaskInfoHostingController()
            controller.onDismiss = { [weak self] in self?.dismiss() }
            popover?.contentViewController = controller
        }
        let height = controller.update(content: content, maximumHeight: max(120, min(380, available - 80)))
        popover?.contentSize = NSSize(width: 300, height: height)
        controller.restoreScrollPosition()
    }
}

@MainActor
private final class TaskInfoHostingController: NSViewController {
    var onDismiss: (() -> Void)?
    private let scrollView = NSScrollView()
    private let document = NSHostingView(rootView: TaskInfoDocument(content: TaskInfoContent(title: "")))
    private var topOffset: CGFloat = 0
    private weak var previousResponder: NSResponder?

    override func loadView() {
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.documentView = document
        view = scrollView
    }

    func update(content: TaskInfoContent, maximumHeight: CGFloat) -> CGFloat {
        loadViewIfNeeded()
        // Keep the actual hosting view and scroll container alive, including their
        // responder chain. Only their content and document height change.
        topOffset = scrollView.contentView.bounds.minY
        previousResponder = view.window?.firstResponder
        document.rootView = TaskInfoDocument(content: content)
        let documentHeight = ceil(document.fittingSize.height)
        let height = min(max(80, documentHeight), maximumHeight)
        document.setFrameSize(NSSize(width: 300, height: documentHeight))
        preferredContentSize = NSSize(width: 300, height: height)
        view.setFrameSize(preferredContentSize)
        view.layoutSubtreeIfNeeded()
        return height
    }

    func restoreScrollPosition() {
        view.layoutSubtreeIfNeeded()
        let maximum = max(0, document.bounds.height - scrollView.contentView.bounds.height)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: min(maximum, max(0, topOffset))))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        if let responder = previousResponder as? NSView, let window = view.window, responder.window === window {
            window.makeFirstResponder(responder)
        }
        previousResponder = nil
    }

    override func cancelOperation(_ sender: Any?) { onDismiss?() }
}

private struct TaskInfoDocument: View {
    let content: TaskInfoContent
    var body: some View {
        TaskInfoBody(content: content).frame(width: 268, alignment: .leading).padding(16)
    }
}

private struct TaskInfoBody: View {
    let content: TaskInfoContent
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(content.title).font(.system(size: 12, weight: .semibold))
            // Paragraph/row positions describe a fixed explanation snapshot, not mutable entities.
            ForEach(content.paragraphs.indices, id: \.self) { index in
                Text(content.paragraphs[index]).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(content.details.indices, id: \.self) { index in
                let detail = content.details[index]
                TaskMetricLayout {
                    Text(detail.label).foregroundStyle(.secondary)
                    Text(detail.value).monospacedDigit()
                }
                .accessibilityElement(children: .combine)
            }
            if content.isUpdating {
                Text("Updating…").foregroundStyle(.secondary)
                    .accessibilityLabel(L10n.text("Updating. Showing the previous recorded result."))
            }
        }
        .font(.system(size: 11))
        .textSelection(.enabled)
    }
}

struct TaskInfoButton: NSViewRepresentable {
    let identifier: String
    let content: TaskInfoContent
    @Environment(\.taskInfoPresenter) private var presenter
    @Environment(\.monitorPanelActive) private var active

    @MainActor final class Coordinator: NSObject {
        weak var presenter: TaskInfoPresenter?
        var identifier = ""
        var content = TaskInfoContent(title: "")
        @objc func invoke(_ button: TaskInfoNativeButton) {
            presenter?.toggle(from: button, identifier: identifier, content: content)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> TaskInfoNativeButton {
        let button = TaskInfoNativeButton(title: "", target: context.coordinator, action: #selector(Coordinator.invoke(_:)))
        button.isBordered = false
        button.setButtonType(.momentaryPushIn)
        button.imagePosition = .imageOnly
        button.focusRingType = .none
        (button.cell as? NSButtonCell)?.highlightsBy = []
        button.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .regular))
        button.contentTintColor = .secondaryLabelColor
        return button
    }
    func updateNSView(_ button: TaskInfoNativeButton, context: Context) {
        let coordinator = context.coordinator
        coordinator.presenter = presenter; coordinator.identifier = identifier; coordinator.content = content
        button.presenter = presenter
        button.isEnabled = active
        button.setAccessibilityIdentifier(identifier)
        button.setAccessibilityLabel(L10n.text("About \(content.title)"))
        button.toolTip = L10n.text("About \(content.title)")
        if active { presenter?.update(anchor: button, identifier: identifier, content: content) }
        else { presenter?.dismiss(ifAnchor: button) }
    }
    static func dismantleNSView(_ button: TaskInfoNativeButton, coordinator: Coordinator) {
        coordinator.presenter?.dismiss(ifAnchor: button)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TaskInfoNativeButton, context: Context) -> CGSize? {
        CGSize(width: 18, height: 18)
    }
}

final class TaskInfoNativeButton: MonitorNativeButton {
    weak var presenter: TaskInfoPresenter?
    private(set) var usesKeyboardFocusAppearance = false
    override var acceptsFirstResponder: Bool { isEnabled }
    override var intrinsicContentSize: NSSize { NSSize(width: 18, height: 18) }

    func setKeyboardFocusAppearance(_ visible: Bool) {
        usesKeyboardFocusAppearance = visible
        needsDisplay = true
    }

    func clearTransientHighlight() {
        highlight(false)
        state = .off
        needsDisplay = true
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted, NSApp.currentEvent?.type == .keyDown { setKeyboardFocusAppearance(true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { setKeyboardFocusAppearance(false) }
        return resigned
    }

    override func mouseDown(with event: NSEvent) {
        setKeyboardFocusAppearance(false)
        defer { clearTransientHighlight() }
        super.mouseDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if isEnabled, usesKeyboardFocusAppearance, window?.isKeyWindow == true, window?.firstResponder === self {
            NSColor.keyboardFocusIndicatorColor.setStroke()
            let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
            ring.lineWidth = 1.5
            ring.stroke()
        }
    }
    override func cancelOperation(_ sender: Any?) {
        if presenter?.shownIdentifier != nil { presenter?.dismiss() }
        else { super.cancelOperation(sender) }
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49 || event.keyCode == 36 {
            if isEnabled, !event.isARepeat {
                setKeyboardFocusAppearance(true)
                performClick(nil)
                clearTransientHighlight()
            }
        } else { super.keyDown(with: event) }
    }
}

/// One leading and one trailing view, so adaptive layout never duplicates native info buttons.
struct TaskMetricLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let ideal = subviews.map { $0.sizeThatFits(.unspecified) }
        let width = proposal.width ?? ideal[0].width + spacing + ideal[1].width
        let horizontal = ideal[0].width + spacing + ideal[1].width <= width
        let sizes = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)) }
        return CGSize(width: width, height: horizontal ? max(ideal[0].height, ideal[1].height)
            : sizes[0].height + spacing + sizes[1].height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let ideal = subviews.map { $0.sizeThatFits(.unspecified) }
        if ideal[0].width + spacing + ideal[1].width <= bounds.width {
            for index in 0..<2 {
                subviews[index].place(at: CGPoint(x: index == 0 ? bounds.minX : bounds.maxX - ideal[index].width,
                    y: bounds.minY + (bounds.height - ideal[index].height) / 2), proposal: .unspecified)
            }
        } else {
            let row = ProposedViewSize(width: bounds.width, height: nil)
            let first = subviews[0].sizeThatFits(row)
            let second = subviews[1].sizeThatFits(row)
            subviews[0].place(at: bounds.origin, proposal: row)
            subviews[1].place(at: CGPoint(x: bounds.maxX - second.width, y: bounds.minY + first.height + spacing), proposal: row)
        }
    }
}

struct TaskUsageSectionTitle: View {
    let title: LocalizedStringKey
    let symbol: String
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).foregroundStyle(.secondary).accessibilityHidden(true)
            Text(title)
        }
        .font(.system(size: 11, weight: .medium))
    }
}
