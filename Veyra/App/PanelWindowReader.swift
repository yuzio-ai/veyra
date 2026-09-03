import AppKit
import SwiftUI

/// Read the actual menu window without replacing its delegate or changing its appearance.
struct PanelWindowReader: NSViewRepresentable {
    var onChange: (PanelScreenMetrics) -> Void
    var onVisibilityChange: (Bool) -> Void = { _ in }

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onChange = onChange
        view.onVisibilityChange = onVisibilityChange
        return view
    }

    func updateNSView(_ view: ReaderView, context: Context) {
        view.onChange = onChange
        view.onVisibilityChange = onVisibilityChange
        view.scheduleRead()
    }

    static func dismantleNSView(_ view: ReaderView, coordinator: ()) {
        view.stop()
    }

    final class ReaderView: NSView {
        var onChange: ((PanelScreenMetrics) -> Void)?
        var onVisibilityChange: ((Bool) -> Void)?
        private var lastVisible: Bool?
        private var lastMetrics: PanelScreenMetrics?
        private var pendingRead: Task<Void, Never>?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            lastMetrics = nil
            guard let window else { scheduleRead(); return }
            for name in [NSWindow.didChangeScreenNotification, NSWindow.didResizeNotification,
                         NSWindow.didBecomeKeyNotification, NSWindow.didMoveNotification,
                         NSWindow.didChangeOcclusionStateNotification, NSWindow.willCloseNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(windowChanged), name: name, object: window)
            }
            NotificationCenter.default.addObserver(self, selector: #selector(windowChanged),
                name: NSApplication.didChangeScreenParametersNotification, object: nil)
            scheduleRead()
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        @objc private func windowChanged(_ notification: Notification) { scheduleRead() }

        func scheduleRead() {
            guard pendingRead == nil else { return }
            // Deliver outside AppKit's layout pass; never mutate SwiftUI state in updateNSView.
            pendingRead = Task { @MainActor [weak self] in
                guard let self, !Task.isCancelled else { return }
                self.pendingRead = nil
                let visible = self.window.map { $0.isVisible && $0.occlusionState.contains(.visible) } ?? false
                if self.lastVisible != visible {
                    self.lastVisible = visible
                    self.onVisibilityChange?(visible)
                }
                guard let window = self.window,
                      let screen = window.screen ?? NSScreen.screens.first(where: {
                          $0.frame.contains(NSEvent.mouseLocation)
                      }) else { return }
                let chrome = max(0, window.frame.height - window.contentRect(forFrameRect: window.frame).height)
                let metrics = PanelScreenMetrics(visibleHeight: screen.visibleFrame.height, windowChromeHeight: chrome)
                guard metrics != self.lastMetrics else { return }
                self.lastMetrics = metrics
                self.onChange?(metrics)
            }
        }

        func stop() {
            pendingRead?.cancel()
            pendingRead = nil
            let visibilityChanged = onVisibilityChange
            Task { @MainActor in visibilityChanged?(false) }
            onVisibilityChange = nil
            onChange = nil
            NotificationCenter.default.removeObserver(self)
        }

        deinit { NotificationCenter.default.removeObserver(self) }
    }
}
