import AppKit
import SwiftUI

/// In-process controls and generated fixtures only; never reads an external AX tree.
@MainActor
enum TaskDetailInteractionChecks {
    private enum CheckError: Error { case failed(String) }

    static func run(to directory: URL) async throws {
        let store = MonitorStore()
        PreviewSupport.configure(store, scenario: .tokenBreakdown)
        let deepTask = store.tasks.first { $0.id == "token-deep" }!
        // Two tasks fit without scrolling so expansion can also verify window shrink.
        store.tasks.removeAll { $0.id == "token-deep" }
        var sizing: PanelSizing?
        let host = NSHostingView(rootView: MonitorPanel(store: store,
            screenOverride: PanelScreenMetrics(visibleHeight: 1_200),
            onSizingChange: { sizing = $0 })
            .environment(\.monitorOpaquePreview, true)
            .environment(\.monitorReferenceDate, PreviewSupport.referenceDate))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: PanelSizing.width, height: 1),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }

        func settle() async throws {
            for _ in 0..<5 {
                try await Task.sleep(for: .milliseconds(50))
                host.layoutSubtreeIfNeeded()
                window.setContentSize(NSSize(width: PanelSizing.width, height: host.fittingSize.height))
            }
        }
        func button(_ id: String) throws -> NSButton {
            guard let button = buttons(host).first(where: { $0.accessibilityIdentifier() == "monitor.tokens." + id }) else {
                throw CheckError.failed("missing token button " + id)
            }
            return button
        }
        func state(_ id: String) throws -> String { String(describing: try button(id).accessibilityValue() ?? "") }
        func expect(_ condition: Bool, _ name: String) throws {
            if !condition { throw CheckError.failed(name) }
        }

        try await settle()
        let initialHeight = sizing?.contentHeight ?? 0
        try expect(initialHeight > 0, "initial measured height")
        try expect(try state("token-parent").contains(L10n.text("Collapsed")), "parent initially collapsed")
        try expect(try state("token-child").contains(L10n.text("Collapsed")), "child initially collapsed")
        try expect(try state("token-parent").contains("436,424,881"), "exact total accessible behind abbreviation")
        try expect(try button("token-parent").toolTip?.contains("436,424,881") == true, "exact total help")

        try button("token-parent").performClick(nil)
        try await settle()
        let parentHeight = sizing?.contentHeight ?? 0
        try expect(parentHeight > initialHeight, "parent details grow actual content")
        try expect(try state("token-parent").contains(L10n.text("Expanded")), "parent expanded")
        try expect(try state("token-child").contains(L10n.text("Collapsed")), "child stays collapsed")
        try button("token-child").performClick(nil)
        try await settle()
        let bothHeight = sizing?.contentHeight ?? 0
        try expect(bothHeight > parentHeight, "child independently expands")
        try PreviewSupport.saveBitmap(host, to: directory.appendingPathComponent("task-details-both-expanded.png"))
        try button("token-parent").performClick(nil)
        try await settle()
        try expect((sizing?.contentHeight ?? 0) < bothHeight, "parent collapse reclaims height")
        try expect(try state("token-child").contains(L10n.text("Expanded")), "child remains expanded")
        let child = try button("token-child")
        try expect(window.makeFirstResponder(child), "token disclosure accepts keyboard focus")
        if let space = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49) {
            window.sendEvent(space)
        }
        try await settle()
        try expect(try state("token-child").contains(L10n.text("Collapsed")), "Space collapses focused token disclosure")
        try expect(abs((sizing?.contentHeight ?? 0) - initialHeight) <= 1, "all collapsed returns to original height")
        try PreviewSupport.saveBitmap(host, to: directory.appendingPathComponent("task-details-both-collapsed.png"))
        store.tasks.append(deepTask)
        try await settle()
        try button("token-deep").performClick(nil)
        try await settle()
        try expect(try state("token-deep").contains(L10n.text("Expanded")), "nested long-value task expands")
        try expect(abs(host.bounds.width - PanelSizing.width) <= 1, "long values preserve panel width")
        try PreviewSupport.saveBitmap(host, to: directory.appendingPathComponent("task-details-long-values.png"))
        let record: [String: Any] = ["fixtureOnly": true, "inProcessControls": true,
            "passed": ["independent-expansion", "independent-collapse", "exact-total-help", "exact-total-accessibility",
                       "keyboard-space", "dynamic-shrink", "nested-long-values"],
            "collapsedContentHeight": initialHeight, "parentExpandedContentHeight": parentHeight,
            "bothExpandedContentHeight": bothHeight]
        try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("task-detail-checks.json"))
        try await checkAPICostDisclosure(to: directory)
        try await checkActionStyle(to: directory)
    }

    private static func checkAPICostDisclosure(to directory: URL) async throws {
        let store = MonitorStore()
        PreviewSupport.configure(store, scenario: .apiCosts)
        store.tasks = [store.tasks[0]]
        let url = directory.appendingPathComponent("api-cost-fixture.jsonl")
        let initial = #"{"type":"turn_context","payload":{"model":"gpt-6.1-sol"}}"# + "\n"
            + #"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":250229,"cached_input_tokens":211840,"output_tokens":1404,"reasoning_output_tokens":420,"total_tokens":251633}}}}"# + "\n"
        try Data(initial.utf8).write(to: url)
        store.tasks[0].apiCostSource = .codex(url)
        let host = NSHostingView(rootView: MonitorPanel(store: store,
            screenOverride: PanelScreenMetrics(visibleHeight: 1_200))
            .environment(\.monitorOpaquePreview, true)
            .environment(\.monitorReferenceDate, PreviewSupport.referenceDate))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: PanelSizing.width, height: 1),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        func settle() async throws {
            for _ in 0..<8 {
                try await Task.sleep(for: .milliseconds(50))
                host.layoutSubtreeIfNeeded()
                window.setContentSize(NSSize(width: PanelSizing.width, height: host.fittingSize.height))
            }
        }
        func toggle() throws {
            guard let button = buttons(host).first(where: { $0.accessibilityIdentifier() == "monitor.tokens.cost-single" }) else {
                throw CheckError.failed("missing API cost disclosure")
            }
            button.performClick(nil)
        }
        let before = await TaskAPICostReader.shared.lastReadByteCount
        try await settle()
        let collapsed = await TaskAPICostReader.shared.lastReadByteCount
        guard before == collapsed else { throw CheckError.failed("collapsed cost must not read history") }
        try toggle(); try await settle()
        let expanded = await TaskAPICostReader.shared.lastReadByteCount
        guard expanded == initial.utf8.count else { throw CheckError.failed("expanded cost must load history once") }
        try PreviewSupport.saveBitmap(host, to: directory.appendingPathComponent("api-cost-live-single.png"))
        try toggle(); try await settle()
        let extra = #"{"type":"turn_context","payload":{"model":"gpt-6.1-terra"}}"# + "\n"
            + #"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":251229,"cached_input_tokens":211840,"output_tokens":1504,"total_tokens":252733}}}}"# + "\n"
        let file = try FileHandle(forWritingTo: url)
        try file.seekToEnd(); try file.write(contentsOf: Data(extra.utf8)); try file.close()
        store.tasks[0] = TaskSnapshot(id: "cost-single", title: store.tasks[0].title, model: "gpt-6.1-terra",
            source: .desktop, parentID: nil, startedAt: PreviewSupport.referenceDate,
            updatedAt: PreviewSupport.referenceDate.addingTimeInterval(1),
            tokens: TokenUsage(input: 251_229, output: 1_504, cachedInput: 211_840, total: 252_733), activity: .running,
            apiCostSource: .codex(url))
        try await settle()
        let afterCollapse = await TaskAPICostReader.shared.lastReadByteCount
        guard afterCollapse == expanded else { throw CheckError.failed("collapsed refresh must not scan cost history") }
        try toggle(); try await settle()
        let incremental = await TaskAPICostReader.shared.lastReadByteCount
        guard incremental == extra.utf8.count else { throw CheckError.failed("reexpanded cost must read only appended history") }
        try PreviewSupport.saveBitmap(host, to: directory.appendingPathComponent("api-cost-live-mixed.png"))
        let record: [String: Any] = ["fixtureOnly": true,
            "passed": ["collapsed-no-read", "expanded-history-read", "collapsed-refresh-no-read", "incremental-reexpand"],
            "initialBytes": expanded, "incrementalBytes": incremental]
        try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("api-cost-disclosure-checks.json"))
    }

    /// Production native controls with safe callbacks, including the quit-shaped button.
    /// No monitoring, settings window, or application termination is invoked here.
    private static func checkActionStyle(to directory: URL) async throws {
        var presses = [0, 0, 0, 0]
        func fixture(enabled: Bool = true) -> ActionStyleFixture {
            ActionStyleFixture(enabled: enabled) { presses[$0] += 1 }
        }
        let host = NSHostingView(rootView: fixture())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 168, height: 60),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }

        for _ in 0..<20 {
            if NSApp.isActive && window.isKeyWindow { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard NSApp.isActive, window.isKeyWindow else {
            throw CheckError.failed("action fixture must own the key window before keyboard dispatch")
        }
        func settle() async throws {
            try await Task.sleep(for: .milliseconds(150))
            host.layoutSubtreeIfNeeded()
        }
        func key(_ code: UInt16, characters: String) throws {
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) else {
                throw CheckError.failed("action fixture keyboard event")
            }
            window.sendEvent(event)
        }

        try await settle()
        let controls = buttons(host).compactMap { $0 as? MonitorActionNativeButton }.sorted {
            $0.accessibilityIdentifier() < $1.accessibilityIdentifier()
        }
        guard controls.count == 4, controls.allSatisfy({ abs($0.bounds.width - 28) <= 0.5 && abs($0.bounds.height - 28) <= 0.5 }),
              abs(host.fittingSize.width - 168) <= 1, abs(host.fittingSize.height - 60) <= 1 else {
            throw CheckError.failed("four 28pt action targets plus spacing and padding; sizes=\(controls.map(\.bounds.size)), fitting=\(host.fittingSize)")
        }
        window.makeFirstResponder(nil)
        try PreviewSupport.saveBitmap(host, to: directory.appendingPathComponent("action-buttons-idle.png"))
        for (index, button) in controls.enumerated() {
            guard window.makeFirstResponder(button) else { throw CheckError.failed("native action accepts focus") }
            try await settle()
            try PreviewSupport.saveBitmap(host, to: directory.appendingPathComponent("action-button-\(index)-focused.png"))
            try key(49, characters: " ")
            try key(36, characters: "\r")
            button.performClick(nil)
            guard presses[index] == 3, presses.reduce(0, +) == (index + 1) * 3 else {
                throw CheckError.failed("native action \(index) invokes once per Space, Return and press")
            }
        }
        guard let entered = NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, trackingNumber: 0, userData: nil) else { throw CheckError.failed("hover fixture event") }
        window.makeFirstResponder(nil)
        controls[0].mouseEntered(with: entered)
        try PreviewSupport.saveBitmap(host, to: directory.appendingPathComponent("action-buttons-hovered.png"))
        controls[0].highlight(true)
        try PreviewSupport.saveBitmap(host, to: directory.appendingPathComponent("action-buttons-pressed.png"))
        controls[0].highlight(false)

        host.rootView = fixture(enabled: false)
        try await settle()
        controls[0].keyDown(with: try disabledKeyEvent(window: window))
        controls[0].performClick(nil)
        guard controls.allSatisfy({ !$0.isEnabled }), presses == [3, 3, 3, 3] else {
            throw CheckError.failed("disabled actions cannot invoke")
        }
        try PreviewSupport.saveBitmap(host, to: directory.appendingPathComponent("action-buttons-disabled.png"))
        let record: [String: Any] = ["fixtureOnly": true, "productionNativeControls": true,
            "targetSize": 28, "spaceReturnAndPressCounts": presses, "disabledBlocked": true,
            "hoverAndPressedEvidence": "native-tracking-callback-and-highlight",
            "quitUsesSafeCallback": true, "keyboardDispatch": "native-window"]
        try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("action-button-checks.json"))
    }

    private static func disabledKeyEvent(window: NSWindow) throws -> NSEvent {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49) else {
            throw CheckError.failed("disabled keyboard fixture event")
        }
        return event
    }

    private struct ActionStyleFixture: View {
        let enabled: Bool
        let press: (Int) -> Void

        var body: some View {
            HStack(spacing: 8) {
                ForEach(0..<4) { index in
                    MonitorActionButton(systemName: ["gearshape", "power", "arrow.clockwise", "arrow.clockwise"][index],
                                        label: "Fixture action \(index)", help: "Safe fixture callback",
                                        identifier: "fixture.monitor.action.\(index)") { press(index) }
                        .disabled(!enabled)
                }
            }
            .padding(16)
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    private static func buttons(_ view: NSView) -> [NSButton] {
        (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons)
    }
}
