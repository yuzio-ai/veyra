import AppKit
import SwiftUI

/// Native controls and numeric fixtures only. No global AX or external account data.
@MainActor
enum TaskInfoInteractionChecks {
    private enum Failure: Error { case check(String) }

    static func run(to directory: URL) async throws {
        let store = MonitorStore()
        PreviewSupport.configure(store, scenario: .apiCosts)
        store.tasks = Array(store.tasks.prefix(2))
        store.tasks[0].contextUsage = ContextWindowUsage(used: 180_100, window: 475_000,
                                                        recordedAt: PreviewSupport.referenceDate)
        store.tasks[0].sessionStatistics = TaskSessionStatistics(toolMilliseconds: 1_084_000,
            meanTTFTMilliseconds: 5_200, ttftSampleCount: 11)
        let presenter = TaskInfoPresenter()
        var sizing: PanelSizing?
        let host = NSHostingView(rootView: MonitorPanel(store: store,
            screenOverride: PanelScreenMetrics(visibleHeight: 1_200),
            onSizingChange: { sizing = $0 }, infoPresenter: presenter)
            .environment(\.monitorOpaquePreview, true)
            .environment(\.monitorReferenceDate, PreviewSupport.referenceDate))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: PanelSizing.width, height: 1),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        defer { presenter.dismiss(restoringFocus: false); window.close() }

        func settle() async throws {
            for _ in 0..<5 {
                try await Task.sleep(for: .milliseconds(50))
                host.layoutSubtreeIfNeeded()
                window.setContentSize(NSSize(width: PanelSizing.width, height: host.fittingSize.height))
            }
        }
        func controls(_ root: NSView) -> [NSButton] {
            (root as? NSButton).map { [$0] } ?? root.subviews.flatMap { controls($0) }
        }
        func control(_ identifier: String) throws -> NSButton {
            guard let found = controls(host).first(where: { $0.accessibilityIdentifier() == identifier }) else {
                throw Failure.check("missing control: " + identifier)
            }
            return found
        }
        func expect(_ value: Bool, _ name: String) throws { if !value { throw Failure.check(name) } }
        func scroll(_ root: NSView) -> NSScrollView? {
            (root as? NSScrollView) ?? root.subviews.lazy.compactMap { scroll($0) }.first
        }
        try await settle()
        let context = try control("monitor.info.context.cost-single")
        let disclosure = try control("monitor.tokens.cost-single")
        let contextFrame = host.convert(context.bounds, from: context)
        let disclosureFrame = host.convert(disclosure.bounds, from: disclosure)
        try expect(host.isFlipped ? contextFrame.midY < disclosureFrame.midY : contextFrame.midY > disclosureFrame.midY,
                   "context precedes disclosure")
        let collapsedHeight = sizing?.contentHeight ?? 0
        try expect(window.makeFirstResponder(context), "info accepts keyboard focus")
        if let space = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49) {
            context.keyDown(with: space)
        }
        try await settle()
        try expect(presenter.shownIdentifier == "monitor.info.context.cost-single", "context opens while collapsed")
        try expect(presenter.window?.isVisible == true, "real explanation popover visible")
        try expect(abs((sizing?.contentHeight ?? 0) - collapsedHeight) <= 1, "explanation does not resize card")
        context.cancelOperation(nil)
        try await settle()
        try expect(presenter.shownIdentifier == nil, "Escape closes explanation")
        try expect(window.firstResponder === context, "Escape restores trigger focus")
        try expect(window.isVisible, "Escape leaves containing window visible")
        guard let infoButton = context as? TaskInfoNativeButton else { throw Failure.check("missing info button type") }
        try expect(infoButton.usesKeyboardFocusAppearance, "keyboard open restores visible keyboard focus")

        // Exercise actual NSButton mouse tracking with a matching queued mouse-up.
        // A programmatic performClick alone cannot reproduce a lingering mouse highlight.
        let clickPoint = context.convert(NSPoint(x: context.bounds.midX, y: context.bounds.midY), to: nil)
        let timestamp = ProcessInfo.processInfo.systemUptime
        guard let mouseDown = NSEvent.mouseEvent(with: .leftMouseDown, location: clickPoint, modifierFlags: [],
            timestamp: timestamp, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1),
              let mouseUp = NSEvent.mouseEvent(with: .leftMouseUp, location: clickPoint, modifierFlags: [],
            timestamp: timestamp + 0.01, windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0) else {
            throw Failure.check("cannot construct mouse input")
        }
        NSApp.postEvent(mouseUp, atStart: true)
        infoButton.mouseDown(with: mouseDown)
        try await settle()
        try expect(presenter.shownIdentifier == "monitor.info.context.cost-single", "mouse opens explanation")
        infoButton.cancelOperation(nil)
        try await settle()
        try expect(presenter.shownIdentifier == nil, "mouse-origin explanation closes")
        try expect(window.firstResponder === context, "mouse origin still restores actionable focus")
        try expect(!infoButton.usesKeyboardFocusAppearance, "mouse origin leaves no keyboard ring")
        try expect(infoButton.state == .off && infoButton.cell?.isHighlighted != true, "mouse highlight clears after close")
        try PreviewSupport.saveBitmap(host, to: directory.appendingPathComponent("task-info-mouse-closed.png"))

        disclosure.performClick(nil)
        try await settle()
        let cost = try control("monitor.info.api-cost.cost-single")
        let tool = try control("monitor.info.tool-time.cost-single")
        cost.performClick(nil)
        try await settle()
        let oldInfoWindow = presenter.window
        tool.performClick(nil)
        try await settle()
        try expect(presenter.shownIdentifier == "monitor.info.tool-time.cost-single", "new field replaces explanation")
        try expect(oldInfoWindow?.isVisible != true, "only one explanation visible")
        disclosure.performClick(nil)
        try await settle()
        try expect(presenter.shownIdentifier == nil, "collapse closes removed field explanation")

        // Use the multi-model cost fixture to require a scrollable explanation.
        try control("monitor.tokens.cost-mixed").performClick(nil)
        try await settle()
        try control("monitor.info.api-cost.cost-mixed").performClick(nil)
        try await settle()
        try expect(presenter.window?.isVisible == true, "multi-model explanation visible")
        guard let infoView = presenter.window?.contentView, let infoScroll = scroll(infoView),
              let document = infoScroll.documentView else { throw Failure.check("missing explanation scroll view") }
        let overflow = document.bounds.height - infoScroll.contentView.bounds.height
        try expect(overflow > 0, "multi-model explanation scrolls")
        infoScroll.contentView.scroll(to: NSPoint(x: 0, y: overflow))
        infoScroll.reflectScrolledClipView(infoScroll.contentView)
        try expect(infoScroll.contentView.bounds.origin.y > 0, "long explanation reaches lower details")
        try await settle()
        try presenter.saveContentPreview(to: directory.appendingPathComponent("task-info-multi-model.png"))
        let controller = presenter.contentController
        try expect(document.isFlipped, "explanation document uses top-origin coordinates")
        // Fixed long content lets the test assert an exact pixel offset in either language.
        let mixedButton = try control("monitor.info.api-cost.cost-mixed")
        guard case .recorded(var revised) = store.tasks[1].apiCostSource else {
            throw Failure.check("missing recorded explanation fixture")
        }
        revised.lines += (0..<15).map { TaskAPICostLine(model: "fixture-model-\($0)", amountUSD: 1) }
        store.tasks[1].apiCostSource = .recorded(revised)
        try await settle()
        infoScroll.contentView.scroll(to: NSPoint(x: 0, y: 200))
        infoScroll.reflectScrolledClipView(infoScroll.contentView)
        try expect(presenter.window?.makeFirstResponder(infoScroll) == true, "explanation scroll accepts focus")
        // NSScrollView may forward first-responder status to its document view.
        let focusedResponder = presenter.window?.firstResponder
        try expect(focusedResponder != nil, "explanation has a focused responder")
        revised.lines[0].amountUSD += 1
        store.tasks[1].contextUsage = ContextWindowUsage(used: 1, window: 100)
        store.tasks[1].apiCostSource = .recorded(revised)
        try await settle()
        try expect(presenter.contentController === controller, "live update preserves controller")
        try expect(presenter.window?.contentView.flatMap { scroll($0) } === infoScroll, "live update preserves scroll view")
        try expect(infoScroll.documentView === document, "live update preserves hosting view")
        try expect(presenter.content?.details.first?.value == TaskAPICostText.amount(revised.total),
                   "live update shows the actual revised total")
        try expect(abs(infoScroll.contentView.bounds.minY - 200) <= 1, "live update preserves 200pt offset")
        try expect(presenter.window?.firstResponder === focusedResponder, "live update preserves keyboard focus")
        store.tasks[1].apiCostSource = .recorded(TaskAPICostEstimate(lines: [
            TaskAPICostLine(model: "fixture-model", amountUSD: 1)
        ]))
        try await settle()
        let shortenedMaximum = max(0, document.bounds.height - infoScroll.contentView.bounds.height)
        try expect(abs(infoScroll.contentView.bounds.minY - min(200, shortenedMaximum)) <= 1,
                   "shortened explanation clamps offset")
        presenter.dismiss()
        mixedButton.performClick(nil)
        try await settle()
        try expect(presenter.window?.contentView.flatMap { scroll($0) }?.contentView.bounds.minY == 0,
                   "reopening starts at top")
        presenter.dismiss()
        try control("monitor.info.context.cost-single").performClick(nil)
        try await settle()
        store.tasks.removeAll { $0.id == "cost-single" }
        try await settle()
        try expect(presenter.shownIdentifier == nil, "removing task closes explanation")
        let remaining = try control("monitor.info.context.cost-mixed")
        remaining.performClick(nil)
        try await settle()
        window.close()
        try expect(presenter.shownIdentifier == nil, "closing parent window closes explanation")

        try JSONSerialization.data(withJSONObject: ["fixtureOnly": true,
            "passed": ["context-before-disclosure", "context-info-while-collapsed", "native-popover",
                       "keyboard-space-open", "no-parent-resize", "escape-close", "focus-restored", "one-explanation",
                       "keyboard-focus-visible", "native-mouse-open-close", "mouse-no-residual-ring", "mouse-highlight-cleared",
                       "collapse-cleanup", "long-explanation-scroll", "live-controller-preserved", "live-scroll-preserved",
                       "live-host-preserved", "live-data-driven-update", "live-offset-200pt", "live-focus-preserved", "short-content-clamp",
                       "reopen-at-top", "task-removal-cleanup", "parent-close-cleanup"]],
            options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("task-info-checks.json"))
        try await checkRefreshStates(to: directory)
    }

    /// Controlled readers suspend only the fixture's requests, so the loading
    /// transitions are deterministic and never touch session files.
    private static func checkRefreshStates(to directory: URL) async throws {
        let costs = TaskInfoFixtureReader<TaskAPICostEstimate>()
        let timings = TaskInfoFixtureReader<TaskSessionStatistics>()
        let presenter = TaskInfoPresenter()
        let source = directory.appendingPathComponent("unused-refresh-fixture.jsonl")
        func task(_ revision: Int, id: String = "refresh", url: URL? = nil) -> TaskSnapshot {
            TaskSnapshot(id: id, title: "Refresh fixture", model: "fixture-model", source: .desktop,
                parentID: nil, startedAt: nil, updatedAt: PreviewSupport.referenceDate.addingTimeInterval(Double(revision)),
                tokens: TokenUsage(total: Int64(revision)), activity: .running, apiCostSource: .codex(url ?? source))
        }
        func root(_ task: TaskSnapshot) -> some View {
            VStack {
                TaskAPICostView(task: task, readEstimate: { _, _ in try await costs.read() })
                TaskSessionStatisticsView(taskID: task.id, source: task.apiCostSource,
                    updatedAt: task.updatedAt, tokens: task.tokens, fixture: nil,
                    readStatistics: { _, _ in try await timings.read() })
            }
            .padding(16).frame(width: 360)
            .environment(\.taskInfoPresenter, presenter).environment(\.monitorPanelActive, true)
        }
        let host = NSHostingView(rootView: root(task(1)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 160),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { presenter.dismiss(restoringFocus: false); window.close() }
        func expect(_ value: Bool, _ name: String) throws { if !value { throw Failure.check(name) } }
        func settle() async throws {
            try await Task.sleep(for: .milliseconds(200))
            host.layoutSubtreeIfNeeded()
        }
        func waitForReads() async throws {
            for _ in 0..<40 {
                if await costs.pendingCount == 1, await timings.pendingCount == 1 { return }
                try await Task.sleep(for: .milliseconds(25))
            }
            throw Failure.check("fixture readers did not receive the current requests")
        }
        func buttons(_ view: NSView) -> [NSButton] {
            if let button = view as? NSButton { return [button] }
            return view.subviews.flatMap { buttons($0) }
        }
        func open(_ field: String, id: String = "refresh") throws {
            guard let button = buttons(host).first(where: {
                $0.accessibilityIdentifier() == "monitor.info.\(field).\(id)"
            }) else { throw Failure.check("missing refresh explanation button") }
            button.performClick(nil)
        }
        let estimate = TaskAPICostEstimate(lines: [TaskAPICostLine(model: "fixture-model", amountUSD: 1)])
        let updated = TaskAPICostEstimate(lines: [TaskAPICostLine(model: "fixture-model", amountUSD: 2)])
        let statistics = TaskSessionStatistics(toolMilliseconds: 1_000, meanTTFTMilliseconds: 1_000, ttftSampleCount: 7)
        let updatedStatistics = TaskSessionStatistics(toolMilliseconds: 2_000, meanTTFTMilliseconds: 2_000, ttftSampleCount: 11)
        try await waitForReads()
        try open("api-cost"); try await settle()
        try expect(presenter.content?.paragraphs.contains(L10n.text("Calculating…")) == true,
                   "first cost load shows calculating")
        try expect(presenter.content?.isUpdating == false, "first cost load has no previous result")
        try open("first-token"); try await settle()
        try expect(presenter.content?.paragraphs.contains(L10n.text("Timing samples unavailable")) == true,
                   "first timing load has no previous samples")
        await costs.finish(estimate); await timings.finish(statistics)
        try await settle()
        try expect(presenter.content?.paragraphs.contains(TaskSessionText.basedOn(7)) == true, "first timing result arrives")
        try open("api-cost"); try await settle()
        let oldDetails = presenter.content?.details
        host.rootView = root(task(2))
        try await waitForReads(); try await settle()
        try expect(presenter.content?.isUpdating == true && presenter.content?.details == oldDetails,
                   "cost refresh retains previous explanation with updating status")
        await costs.finish(updated); await timings.finish(updatedStatistics)
        try await settle()
        try expect(presenter.content?.isUpdating == false && presenter.content?.details != oldDetails,
                   "cost refresh replaces previous explanation")
        try open("first-token"); try await settle()
        host.rootView = root(task(3))
        try await waitForReads(); try await settle()
        try expect(presenter.content?.isUpdating == true
            && presenter.content?.paragraphs.contains(TaskSessionText.basedOn(11)) == true,
                   "timing refresh retains previous sample count with updating status")
        await costs.fail(); await timings.fail()
        try await settle()
        try expect(presenter.content?.isUpdating == false
            && presenter.content?.paragraphs.contains(TaskSessionText.basedOn(0)) == true,
                   "timing failure replaces previous samples")
        try open("api-cost"); try await settle()
        try expect(presenter.content?.paragraphs.contains(TaskAPICostIssue.historyUnreadable.text) == true
            && presenter.content?.details.count == 1, "cost failure replaces previous model rows")

        host.rootView = root(task(4))
        try await waitForReads()
        await costs.finish(estimate); await timings.finish(statistics)
        try await settle()
        host.rootView = root(task(5, url: directory.appendingPathComponent("other-unused-source.jsonl")))
        try await waitForReads(); try await settle()
        try expect(presenter.content?.details.isEmpty == true && presenter.content?.isUpdating == false,
                   "source change drops previous cost explanation")
        try open("first-token"); try await settle()
        try expect(presenter.content?.paragraphs.contains(TaskSessionText.basedOn(7)) == false,
                   "source change drops previous timing samples")
        await costs.finish(estimate); await timings.finish(statistics)
        try await settle()
        host.rootView = root(task(6, id: "other-task"))
        try await waitForReads(); try await settle()
        try expect(presenter.shownIdentifier == nil, "task identity change closes the old explanation")
        try open("api-cost", id: "other-task"); try await settle()
        try expect(presenter.content?.details.isEmpty == true && presenter.content?.isUpdating == false,
                   "task change drops previous cost explanation")
        try open("first-token", id: "other-task"); try await settle()
        try expect(presenter.content?.paragraphs.contains(TaskSessionText.basedOn(7)) == false,
                   "task change drops previous timing samples")
        await costs.finish(updated); await timings.finish(updatedStatistics)
        try await settle()
        try JSONSerialization.data(withJSONObject: ["fixtureOnly": true,
            "passed": ["initial-loading", "cost-refresh-retention", "cost-refresh-replacement",
                       "timing-refresh-retention", "failure-replacement", "source-isolation", "task-isolation"]],
            options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("task-info-refresh-checks.json"))
    }
}

private actor TaskInfoFixtureReader<Value: Sendable> {
    private var pending: [UUID: CheckedContinuation<Value, Error>] = [:]
    var pendingCount: Int { pending.count }

    func read() async throws -> Value {
        try Task.checkCancellation()
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { pending[id] = $0 }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }
    func finish(_ value: Value) {
        let requests = pending; pending.removeAll()
        for request in requests.values { request.resume(returning: value) }
    }
    func fail() {
        let requests = pending; pending.removeAll()
        for request in requests.values { request.resume(throwing: CocoaError(.fileReadUnknown)) }
    }
    private func cancel(_ id: UUID) { pending.removeValue(forKey: id)?.resume(throwing: CancellationError()) }
}
