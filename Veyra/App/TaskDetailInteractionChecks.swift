import AppKit
import SwiftUI
import Observation

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
        try await checkQuotaCooldown(to: directory)
        try await checkSourceNotices(to: directory)
        try await checkActionStyle(to: directory)
    }

    private static func checkSourceNotices(to directory: URL) async throws {
        let suite = "veyra-source-notice-fixture-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let store = MonitorStore(defaults: defaults, inspectServices: { _ in false },
            resolveLocation: { _, _ in CodexLocation(home: directory, executable: nil) })
        PreviewSupport.configure(store, scenario: .single)
        store.taskWarning = .historyUnavailable
        store.dshWarning = L10n.text("Some dsh session records are unreadable.")
        let presenter = TaskInfoPresenter()
        let host = NSHostingView(rootView: MonitorPanel(store: store,
            screenOverride: PanelScreenMetrics(visibleHeight: 1_200), openSettings: {}, infoPresenter: presenter)
            .environment(\.monitorOpaquePreview, true)
            .environment(\.monitorReferenceDate, PreviewSupport.referenceDate))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: PanelSizing.width, height: 600),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { presenter.dismiss(restoringFocus: false); window.close() }

        func settle() async throws {
            for _ in 0..<5 {
                try await Task.sleep(for: .milliseconds(50))
                host.layoutSubtreeIfNeeded()
                window.setContentSize(NSSize(width: PanelSizing.width, height: host.fittingSize.height))
            }
        }
        func warningButtons() -> [NSButton] {
            buttons(host).filter { $0.accessibilityIdentifier() == "monitor.info.taskSources" }
        }
        func expect(_ condition: Bool, _ name: String) throws {
            if !condition { throw CheckError.failed(name) }
        }

        try await settle()
        try expect(warningButtons().count == 1, "multiple task warnings share one explanation")
        try PreviewSupport.saveBitmap(host, to: directory.appendingPathComponent("source-warning-summary-light.png"))
        let trigger = warningButtons()[0]
        try expect(window.makeFirstResponder(trigger), "source explanation accepts keyboard focus")
        guard let space = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49) else {
            throw CheckError.failed("source explanation key event")
        }
        window.sendEvent(space)
        try await settle()
        try expect(presenter.shownIdentifier == "monitor.info.taskSources", "Space opens source explanation")
        try expect(presenter.content?.details.map(\.label) == ["Codex", "dsh"], "source labels remain distinct")
        try expect(presenter.content?.details.first?.value == TaskReadWarning.historyUnavailable.message,
                   "history fallback reason remains available")
        try presenter.saveContentPreview(to: directory.appendingPathComponent("source-warning-details.png"))

        store.taskWarning = nil
        try await settle()
        try expect(presenter.content?.details.map(\.label) == ["dsh"], "open explanation removes recovered source")
        trigger.cancelOperation(nil)
        try await settle()
        try expect(presenter.shownIdentifier == nil && window.firstResponder === trigger,
                   "Escape returns focus to source trigger")
        trigger.performClick(nil)
        try await settle()
        store.dshWarning = nil
        try await settle()
        try expect(warningButtons().isEmpty && presenter.shownIdentifier == nil,
                   "all sources recovering removes notice and closes explanation")

        store.executablePath = "/preview/missing-codex"
        store.previewCodexServicesAvailable = false
        store.refreshServiceAvailability()
        try await settle()
        try expect(store.codexServiceWarning != nil && !store.hasSourceWarning,
                   "quota path warning keeps task health normal")
        try expect(warningButtons().isEmpty, "quota path warning does not create task notice")
        try PreviewSupport.saveBitmap(host, to: directory.appendingPathComponent("quota-path-warning-light.png"))
        store.taskError = L10n.text("Unable to read Codex task records. Check its data directory.")
        try await settle()
        try expect(warningButtons().count == 1 && store.hasSourceWarning,
                   "task failure remains visible beside quota path warning")
        window.appearance = NSAppearance(named: .darkAqua)
        try await settle()
        try expect(abs(host.bounds.width - PanelSizing.width) <= 1, "warning content preserves panel width")
        try PreviewSupport.saveBitmap(host, to: directory.appendingPathComponent("source-and-quota-warnings-dark.png"))
        let record: [String: Any] = ["fixtureOnly": true, "inProcessControls": true,
            "passed": ["single-summary", "source-details", "history-fallback", "keyboard-space", "escape-focus",
                       "live-recovery", "removed-anchor-dismissal", "quota-task-isolation", "simultaneous-failures"]]
        try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("source-warning-checks.json"))
    }

    /// Mount the production panel without its fixed preview clock. The store stays
    /// in preview mode, so clicking can never access an account or start monitoring.
    private static func checkQuotaCooldown(to directory: URL) async throws {
        let store = MonitorStore()
        PreviewSupport.configure(store, scenario: .single)
        let state = QuotaCooldownFixtureState()
        let host = NSHostingView(rootView: QuotaCooldownFixture(store: store, state: state))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: PanelSizing.width, height: 600),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }

        func button() throws -> MonitorActionNativeButton {
            guard let button = buttons(host).compactMap({ $0 as? MonitorActionNativeButton })
                .first(where: { $0.accessibilityIdentifier() == "monitor.calibrate" }) else {
                throw CheckError.failed("current mounted quota button")
            }
            return button
        }
        func expectEnabled(_ enabled: Bool, _ phase: String) async throws {
            let timeout = Date().addingTimeInterval(3)
            while Date() < timeout {
                host.layoutSubtreeIfNeeded()
                if let control = try? button(), control.isEnabled == enabled { return }
                try await Task.sleep(for: .milliseconds(30))
            }
            throw CheckError.failed("quota cooldown: \(phase)")
        }
        func waitPast(_ date: Date) async throws {
            try await Task.sleep(for: .seconds(max(0, date.timeIntervalSinceNow) + 0.15))
        }

        try await expectEnabled(true, "initially ready")
        let originalDeadline = Date().addingTimeInterval(1.2)
        store.nextCalibrationAt = originalDeadline
        store.quotaBusy = true
        try await expectEnabled(false, "request in progress")
        store.quotaBusy = false
        try await Task.sleep(for: .milliseconds(150))
        try await expectEnabled(false, "request finished before deadline")
        for _ in 0..<10 { try button().performClick(nil) }
        try button().keyDown(with: disabledKeyEvent(window: window))
        try await expectEnabled(false, "repeated clicks and keyboard remain disabled")
        try PreviewSupport.saveBitmap(host, to: directory.appendingPathComponent("quota-cooldown-disabled.png"))

        let extendedDeadline = Date().addingTimeInterval(3)
        store.nextCalibrationAt = extendedDeadline
        try await waitPast(originalDeadline)
        try await expectEnabled(false, "old deadline cannot unlock extended cooldown")
        state.shown = false
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        guard buttons(host).isEmpty else { throw CheckError.failed("quota fixture unmounted") }
        state.shown = true
        try await Task.sleep(for: .milliseconds(100))
        try await expectEnabled(false, "reopened before deadline")
        try await waitPast(extendedDeadline)
        try await expectEnabled(true, "deadline restores button")
        try PreviewSupport.saveBitmap(host, to: directory.appendingPathComponent("quota-cooldown-ready.png"))

        let secondDeadline = Date().addingTimeInterval(0.5)
        store.nextCalibrationAt = secondDeadline
        try await expectEnabled(false, "second cooldown")
        state.shown = false
        try await waitPast(secondDeadline)
        state.shown = true
        try await expectEnabled(true, "reopened after deadline")
        store.nextCalibrationAt = Date().addingTimeInterval(2)
        try await expectEnabled(false, "new deadline")
        store.nextCalibrationAt = nil
        try await expectEnabled(true, "cleared deadline")

        let record: [String: Any] = ["fixtureOnly": true, "productionPanel": true, "realClock": true,
            "passed": ["in-flight-disabled", "cooldown-disabled", "repeated-clicks-disabled", "deadline-extension",
                       "reopen-before-deadline", "deadline-restores", "second-cooldown", "reopen-after-deadline", "deadline-cleared"]]
        try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("quota-cooldown-checks.json"))
    }

    @MainActor @Observable fileprivate final class QuotaCooldownFixtureState {
        var shown = true
    }

    private struct QuotaCooldownFixture: View {
        let store: MonitorStore
        let state: QuotaCooldownFixtureState

        var body: some View {
            if state.shown {
                MonitorPanel(store: store, screenOverride: PanelScreenMetrics(visibleHeight: 1_200))
                    .environment(\.monitorOpaquePreview, true)
            } else { Color.clear.frame(width: PanelSizing.width, height: 1) }
        }
    }

    private static func checkAPICostDisclosure(to directory: URL) async throws {
        let store = MonitorStore()
        PreviewSupport.configure(store, scenario: .apiCosts)
        store.tasks = [store.tasks[0]]
        let url = directory.appendingPathComponent("api-cost-fixture.jsonl")
        let initial = #"{"type":"turn_context","payload":{"model":"gpt-6.1-sol"}}"# + "\n"
            + #"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":250229,"cached_input_tokens":211840,"output_tokens":1404,"reasoning_output_tokens":420,"total_tokens":251633}}}}"# + "\n"
            + #"{"type":"event_msg","payload":{"type":"item_completed","thread_id":"cost-single","turn_id":"previous","started_at_ms":1000,"completed_at_ms":5000,"item":{"type":"CommandExecution","id":"tool"}}}"# + "\n"
            + #"{"type":"event_msg","payload":{"type":"task_complete","turn_id":"previous","time_to_first_token_ms":1300}}"# + "\n"
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
        let statisticsBefore = await TaskSessionStatisticsReader.shared.lastReadByteCount
        try await settle()
        let collapsed = await TaskAPICostReader.shared.lastReadByteCount
        guard before == collapsed else { throw CheckError.failed("collapsed cost must not read history") }
        let statisticsCollapsed = await TaskSessionStatisticsReader.shared.lastReadByteCount
        guard statisticsBefore == statisticsCollapsed else { throw CheckError.failed("collapsed statistics must not read history") }
        try toggle(); try await settle()
        let expanded = await TaskAPICostReader.shared.lastReadByteCount
        guard expanded == initial.utf8.count else { throw CheckError.failed("expanded cost must load history once") }
        let statisticsExpanded = await TaskSessionStatisticsReader.shared.lastReadByteCount
        guard statisticsExpanded == initial.utf8.count else { throw CheckError.failed("expanded statistics must load history once") }
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
        let statisticsAfterCollapse = await TaskSessionStatisticsReader.shared.lastReadByteCount
        guard statisticsAfterCollapse == statisticsExpanded else { throw CheckError.failed("collapsed refresh must not scan statistics") }
        guard afterCollapse == expanded else { throw CheckError.failed("collapsed refresh must not scan cost history") }
        try toggle(); try await settle()
        let incremental = await TaskAPICostReader.shared.lastReadByteCount
        guard incremental == extra.utf8.count else { throw CheckError.failed("reexpanded cost must read only appended history") }
        let statisticsIncremental = await TaskSessionStatisticsReader.shared.lastReadByteCount
        guard statisticsIncremental == extra.utf8.count else { throw CheckError.failed("reexpanded statistics must read only appended history") }
        let timingOnly = #"{"type":"event_msg","payload":{"type":"item_completed","thread_id":"cost-single","turn_id":"current","started_at_ms":4000,"completed_at_ms":8000,"item":{"type":"McpToolCall","id":"second-tool"}}}"# + "\n"
            + #"{"type":"event_msg","payload":{"type":"task_complete","turn_id":"current","time_to_first_token_ms":3000}}"# + "\n"
        let timingFile = try FileHandle(forWritingTo: url)
        try timingFile.seekToEnd(); try timingFile.write(contentsOf: Data(timingOnly.utf8)); try timingFile.close()
        // A file revision alone must refresh statistics, even without another token_count.
        store.tasks[0].rolloutModifiedAt = PreviewSupport.referenceDate.addingTimeInterval(2)
        try await settle()
        let liveTimingBytes = await TaskSessionStatisticsReader.shared.lastReadByteCount
        guard liveTimingBytes == timingOnly.utf8.count else { throw CheckError.failed("active statistics must refresh on timing-only append") }
        try PreviewSupport.saveBitmap(host, to: directory.appendingPathComponent("api-cost-live-mixed.png"))
        let record: [String: Any] = ["fixtureOnly": true,
            "passed": ["collapsed-no-read", "expanded-history-read", "collapsed-refresh-no-read", "incremental-reexpand",
                       "statistics-collapsed-no-read", "statistics-expanded-history-read", "statistics-collapsed-refresh-no-read",
                       "statistics-incremental-reexpand", "statistics-timing-only-live-update"],
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
