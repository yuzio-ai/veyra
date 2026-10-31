import AppKit
import SwiftUI

private struct OpaquePreviewKey: EnvironmentKey {
    static let defaultValue = false
}

private struct MonitorReferenceDateKey: EnvironmentKey {
    static let defaultValue: Date? = nil
}

private struct MonitorPreviewContrastKey: EnvironmentKey {
    static let defaultValue: ColorSchemeContrast? = nil
}

extension EnvironmentValues {
    /// Developer-only layout rendering; never changes the system setting.
    var monitorOpaquePreview: Bool {
        get { self[OpaquePreviewKey.self] }
        set { self[OpaquePreviewKey.self] = newValue }
    }

    /// Freeze timestamps in explicit developer fixtures, never in the live monitor.
    var monitorReferenceDate: Date? {
        get { self[MonitorReferenceDateKey.self] }
        set { self[MonitorReferenceDateKey.self] = newValue }
    }

    /// A fixture input: the real accessibility contrast environment is read-only.
    var monitorPreviewContrast: ColorSchemeContrast? {
        get { self[MonitorPreviewContrastKey.self] }
        set { self[MonitorPreviewContrastKey.self] = newValue }
    }
}

struct ControlCenterTile: ViewModifier {
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.monitorPreviewContrast) private var previewContrast
    @Environment(\.monitorOpaquePreview) private var opaquePreview

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        let increasedContrast = (previewContrast ?? contrast) == .increased
        content
            .background {
                if reduceTransparency || opaquePreview {
                    shape.fill(Color(nsColor: .controlBackgroundColor))
                } else {
                    // The system owns the popover material; scrolling cards use
                    // vibrant fill and a semantic separator, never another glass layer.
                    shape.fill(.quaternary)
                }
            }
            .overlay {
                shape.strokeBorder(increasedContrast ? Color.primary : Color(nsColor: .separatorColor),
                                   lineWidth: increasedContrast ? 1 : 1 / max(1, displayScale))
                    .allowsHitTesting(false)
            }
    }
}

/// Borderless native controls keep AppKit focus and keyboard dispatch inside the popover.
struct MonitorActionButton: NSViewRepresentable {
    let systemName: String
    let label: String
    let help: String
    let identifier: String
    var action: @MainActor () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.monitorPreviewContrast) private var previewContrast

    @MainActor final class Coordinator: NSObject {
        var action: @MainActor () -> Void
        init(action: @escaping @MainActor () -> Void) { self.action = action }
        @objc func invoke(_ sender: NSButton) {
            guard sender.isEnabled else { return }
            action()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    func makeNSView(context: Context) -> MonitorActionNativeButton {
        let button = MonitorActionNativeButton(title: "", target: context.coordinator,
                                               action: #selector(Coordinator.invoke(_:)))
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.imagePosition = .imageOnly
        button.focusRingType = .none
        (button.cell as? NSButtonCell)?.highlightsBy = []
        return button
    }

    func updateNSView(_ button: MonitorActionNativeButton, context: Context) {
        context.coordinator.action = action
        button.image = NSImage(systemSymbolName: systemName, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .medium))
        button.isEnabled = isEnabled
        button.increasedContrast = (previewContrast ?? contrast) == .increased
        button.toolTip = help
        button.setAccessibilityLabel(label)
        button.setAccessibilityIdentifier(identifier)
        button.needsDisplay = true
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MonitorActionNativeButton, context: Context) -> CGSize? {
        CGSize(width: 28, height: 28)
    }
}

@MainActor
protocol MonitorMenuDismissalHandling: AnyObject {
    func dismissMenu()
}

/// Route Escape through the menu owner before AppKit closes its transient popover.
class MonitorNativeButton: NSButton {
    override func cancelOperation(_ sender: Any?) {
        var responder = nextResponder
        while let current = responder {
            if let owner = current as? any MonitorMenuDismissalHandling {
                owner.dismissMenu()
                return
            }
            responder = current.nextResponder
        }
        if let owner = window?.contentViewController as? any MonitorMenuDismissalHandling {
            owner.dismissMenu()
        } else {
            super.cancelOperation(sender)
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { cancelOperation(nil) }
        else { super.keyDown(with: event) }
    }
}

final class MonitorActionNativeButton: MonitorNativeButton {
    var increasedContrast = false
    private var hovered = false
    private var hoverTracking: NSTrackingArea?

    override var intrinsicContentSize: NSSize { NSSize(width: 28, height: 28) }
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0) }
    override var acceptsFirstResponder: Bool { isEnabled }
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        needsDisplay = true
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        needsDisplay = true
        return resigned
    }

    override func updateTrackingAreas() {
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let tracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                      owner: self, userInfo: nil)
        addTrackingArea(tracking)
        hoverTracking = tracking
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        if isEnabled, hovered || cell?.isHighlighted == true {
            let pressed = cell?.isHighlighted == true
            let opacity = pressed ? (increasedContrast ? 0.22 : 0.12) : (increasedContrast ? 0.14 : 0.07)
            NSColor.labelColor.withAlphaComponent(opacity).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        }
        super.draw(dirtyRect)
        if isEnabled, window?.isKeyWindow == true, window?.firstResponder === self {
            // Borderless cells omit their ring when Full Keyboard Access is off.
            // Keep programmatically focused controls visible in that mode too.
            NSColor.keyboardFocusIndicatorColor.setStroke()
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5)
            ring.lineWidth = 2
            ring.stroke()
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49 || event.keyCode == 36 {
            if isEnabled, !event.isARepeat { performClick(nil) }
        } else { super.keyDown(with: event) }
    }
}
