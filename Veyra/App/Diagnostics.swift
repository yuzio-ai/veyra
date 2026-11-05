import Foundation
import AppKit

@MainActor
enum Diagnostics {
    static var menuWindow: (() -> NSWindow?)?
    static var toggleMenu: (() -> Void)?

    static func traceMenuFocus(_ phase: String) {
        guard CommandLine.arguments.contains("--exercise-menu-to") else { return }
        let window = menuWindow?()
        print("Menu focus \(ProcessInfo.processInfo.systemUptime): \(phase), active=\(NSApp.isActive), key=\(window?.isKeyWindow == true), visible=\(window?.isVisible == true), front=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown")")
    }

    /// The fixed LaunchServices runner revokes this lease on timeout/interruption.
    /// Record identity before checking it, so even a delayed launch cannot outlive the runner.
    static func validatePreviewLease() throws {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--preview-lease") else {
            if arguments.contains("--preview-focus-host") { throw MenuCheckError.invalidLease }
            return
        }
        guard arguments.indices.contains(index + 1), UUID(uuidString: arguments[index + 1]) != nil else {
            throw MenuCheckError.invalidLease
        }
        let destination: Int
        if let host = arguments.firstIndex(of: "--preview-focus-host") {
            destination = host
        } else if let render = arguments.firstIndex(of: "--render-previews"), PreviewSupport.menuScenario == nil {
            destination = render
        } else if let exercise = arguments.firstIndex(of: "--exercise-menu-to"),
                  PreviewSupport.menuScenario != nil, arguments.contains("--exit-after-menu-checks"),
                  !arguments.contains("--render-previews") {
            destination = exercise
        } else { throw MenuCheckError.invalidLease }
        guard arguments.indices.contains(destination + 1) else { throw MenuCheckError.invalidLease }
        let directory = URL(fileURLWithPath: arguments[destination + 1], isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let token = arguments[index + 1]
        let receipt: [String: Any] = ["pid": ProcessInfo.processInfo.processIdentifier, "group": getpgrp(), "token": token]
        try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys])
            .write(to: directory.appendingPathComponent("process.json"), options: [.atomic])
        guard try String(contentsOf: directory.appendingPathComponent("active-lease"), encoding: .utf8) == token else {
            throw MenuCheckError.invalidLease
        }
    }
    /// Opt-in interaction smoke test against the actual menu window, not a substitute window.
    /// Images remain layout-only; this never requests screen recording permission.
    static func exerciseNextMenu(to directory: URL) {
        Task { @MainActor in
            let center = NotificationCenter.default
            let focusObservers = [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
                                  NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification].map { name in
                center.addObserver(forName: name, object: nil, queue: .main) { notification in
                    let phase = notification.name.rawValue
                    MainActor.assumeIsolated { traceMenuFocus(phase) }
                }
            }
            defer { focusObservers.forEach { center.removeObserver($0) } }
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                for _ in 0..<300 {
                    try await Task.sleep(for: .milliseconds(200))
                    guard let window = menuWindow?(), window.isVisible,
                          let view = window.contentView else { continue }
                    try await Task.sleep(for: .milliseconds(700))
                    let effectiveAppearance = view.effectiveAppearance.name
                    guard let requestedAppearance = PreviewSupport.menuAppearance,
                          let resolvedAppearance = NSAppearance(named: requestedAppearance)?.name,
                          effectiveAppearance == resolvedAppearance else {
                        print("Menu appearance mismatch: requested=\(PreviewSupport.menuAppearance?.rawValue ?? "none"), resolved=\(PreviewSupport.menuAppearance.flatMap { NSAppearance(named: $0)?.name.rawValue } ?? "none"), effective=\(effectiveAppearance.rawValue)")
                        throw MenuCheckError.appearanceMismatch
                    }
                    guard let scroll = scrollView(in: view), let document = scroll.documentView else {
                        throw MenuCheckError.missingScrollView
                    }
                    var records: [[String: Any]] = [["position": "appearance",
                        "requestedAppearance": requestedAppearance.rawValue,
                        "resolvedAppearance": resolvedAppearance.rawValue,
                        "effectiveAppearance": effectiveAppearance.rawValue,
                        "increasedContrast": PreviewSupport.menuIncreasedContrast,
                        "reduceTransparency": PreviewSupport.menuReduceTransparency]]
                    let originalHeight = window.frame.height
                    let maximumOffset = max(0, document.bounds.height - scroll.contentView.bounds.height)
                    guard maximumOffset > 0 else { throw MenuCheckError.expectedOverflow }
                    for (name, offset) in [("top", CGFloat(0)), ("middle", maximumOffset / 2), ("bottom", maximumOffset)] {
                        scroll.contentView.scroll(to: NSPoint(x: 0, y: offset))
                        scroll.reflectScrolledClipView(scroll.contentView)
                        try await Task.sleep(for: .milliseconds(150))
                        view.layoutSubtreeIfNeeded()
                        guard abs(window.frame.height - originalHeight) < 1 else { throw MenuCheckError.unstableHeight }
                        try PreviewSupport.saveBitmap(view, to: directory.appendingPathComponent("\(name)-layout.png"))
                        records.append(["position": name, "windowHeight": window.frame.height,
                                        "offset": scroll.contentView.bounds.origin.y,
                                        "viewportHeight": scroll.contentView.bounds.height,
                                        "documentHeight": document.bounds.height])
                    }
                    // Rapid alternating scroll commands exercise viewport clipping and clamping.
                    for index in 0..<12 {
                        scroll.contentView.scroll(to: NSPoint(x: 0, y: index.isMultiple(of: 2) ? -120 : maximumOffset + 120))
                        scroll.reflectScrolledClipView(scroll.contentView)
                        try await Task.sleep(for: .milliseconds(20))
                    }
                    scroll.contentView.scroll(to: .zero)
                    scroll.reflectScrolledClipView(scroll.contentView)
                    // A short snapshot must shrink this very same menu window while it remains open.
                    PreviewSupport.configure(MonitorStore.shared, scenario: .single)
                    try await Task.sleep(for: .milliseconds(700))
                    view.layoutSubtreeIfNeeded()
                    guard window.frame.height < originalHeight else { throw MenuCheckError.didNotShrink }
                    try PreviewSupport.saveBitmap(view, to: directory.appendingPathComponent("shrunk-layout.png"))
                    records.append(["position": "shrunk", "windowHeight": window.frame.height])
                    // Cover a closed baseline on every run, including when AppKit
                    // did not dismiss the transient menu during the layout checks.
                    let forcedRecovery = window.isVisible
                    if forcedRecovery {
                        toggleMenu?()
                        guard await waitForStable({ !window.isVisible }) else { throw MenuCheckError.didNotClose }
                    }
                    // A transient popover can be dismissed by a foreground-app change during
                    // the asynchronous layout checks. Establish the shown baseline before
                    // testing toggle-to-close, otherwise toggle would reopen it instead.
                    let restoredVisibilityBeforeToggle = !window.isVisible
                    if restoredVisibilityBeforeToggle {
                        print("Fixture dismissed before toggle check; restoring the shown baseline")
                        _ = try await prepareBackgroundMenu(in: directory)
                        toggleMenu?()
                        guard await waitForStable({ menuWindow?()?.isVisible == true
                            && menuWindow?()?.isKeyWindow == true && NSApp.isActive }) else {
                            throw MenuCheckError.keyboardFocusUnavailable
                        }
                    }
                    guard let closing = menuWindow?(), closing.isVisible else { throw MenuCheckError.didNotOpen }
                    // Exercise the same controller used by the registered hotkey and status button.
                    toggleMenu?()
                    guard await waitForStable({ !closing.isVisible }) else { throw MenuCheckError.didNotClose }
                    let previousApplication = try await prepareBackgroundMenu(in: directory)
                    toggleMenu?()
                    guard await waitFor({ menuWindow?()?.isVisible == true }) else { throw MenuCheckError.didNotOpen }
                    guard let reopened = menuWindow?(), reopened.isVisible else { throw MenuCheckError.didNotOpen }
                    // LaunchServices brings the fixed fixture to the foreground. Require a real
                    // key window before dispatching a synthetic event through its responder chain.
                    guard await waitForStable({ NSApp.isActive && reopened.isKeyWindow }) else {
                        print("Keyboard focus unavailable: app=\(ProcessInfo.processInfo.processIdentifier), front=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1), active=\(NSApp.isActive), policy=\(NSApp.activationPolicy().rawValue), canKey=\(reopened.canBecomeKey), key=\(reopened.isKeyWindow), visible=\(reopened.isVisible), appKey=\(NSApp.keyWindow?.windowNumber ?? -1), popover=\(reopened.windowNumber)")
                        throw MenuCheckError.keyboardFocusUnavailable
                    }
                    // Drive the explanation through its actual SwiftUI data source.
                    // Direct presenter injection can be overwritten by a normal anchor
                    // update, legitimately shortening the document and clamping to zero.
                    var explanationEstimate = TaskAPICostEstimate(lines: (0..<30).map {
                        TaskAPICostLine(model: "fixture-model-\($0)", lowerUSD: 1, upperUSD: 1)
                    })
                    guard let taskID = MonitorStore.shared.tasks.first?.id,
                          let disclosure = reopened.contentView.flatMap({ menuControl(in: $0, id: "monitor.tokens." + taskID) }) else {
                        throw MenuCheckError.missingCostControls
                    }
                    MonitorStore.shared.tasks[0].apiCostSource = .recorded(explanationEstimate)
                    disclosure.performClick(nil)
                    guard await waitForStable({ reopened.contentView.flatMap({ infoControl(in: $0, kind: "api-cost") }) != nil }),
                          let info = reopened.contentView.flatMap({ infoControl(in: $0, kind: "api-cost") }),
                          let presenter = info.presenter else {
                        throw MenuCheckError.missingCostControls
                    }
                    info.scrollToVisible(info.bounds)
                    info.performClick(nil)
                    guard await waitForStable({ presenter.window?.isVisible == true
                        && presenter.window?.isKeyWindow == true && NSApp.isActive && reopened.isVisible }),
                          let infoWindow = presenter.window else { throw MenuCheckError.didNotOpen }
                    // Repeat the live explanation regression under every native appearance.
                    guard let infoController = presenter.contentController,
                          let infoScroll = infoWindow.contentView.flatMap({ scrollView(in: $0) }),
                          let infoDocument = infoScroll.documentView else { throw MenuCheckError.didNotOpen }
                    infoWindow.contentView?.layoutSubtreeIfNeeded()
                    // Showing/resizing a popover schedules AppKit and SwiftUI focus
                    // work. Establish a settled input target before testing updates.
                    guard await waitForStable({ presenter.window === infoWindow && infoWindow.isKeyWindow
                        && NSApp.isActive && infoScroll.window === infoWindow
                        && presenter.content?.details.count == 31
                        && infoDocument.bounds.height - infoScroll.contentView.bounds.height >= 200 }) else {
                        print("Info input not ready: sameWindow=\(presenter.window === infoWindow), key=\(infoWindow.isKeyWindow), active=\(NSApp.isActive), attached=\(infoScroll.window === infoWindow), documentHeight=\(infoDocument.bounds.height), viewport=\(infoScroll.contentView.bounds.height), details=\(presenter.content?.details.count ?? -1)")
                        throw MenuCheckError.keyboardFocusUnavailable
                    }
                    infoScroll.contentView.scroll(to: NSPoint(x: 0, y: 200))
                    infoScroll.reflectScrolledClipView(infoScroll.contentView)
                    guard infoWindow.makeFirstResponder(infoScroll) else {
                        print("Info scroll rejected focus: key=\(infoWindow.isKeyWindow), attached=\(infoScroll.window === infoWindow)")
                        throw MenuCheckError.keyboardFocusUnavailable
                    }
                    let infoResponder = infoWindow.firstResponder
                    // Simulate a normal monitored snapshot arriving while this
                    // explanation is open, including its declarative anchor update.
                    MonitorStore.shared.tasks[0].contextUsage = ContextWindowUsage(used: 1, window: 100)
                    explanationEstimate.lines[0].lowerUSD = 2
                    explanationEstimate.lines[0].upperUSD = 2
                    MonitorStore.shared.tasks[0].apiCostSource = .recorded(explanationEstimate)
                    let expectedAmount = TaskAPICostText.amount(explanationEstimate.total)
                    guard await waitForStable({ presenter.content?.details.first?.value == expectedAmount
                        && abs(infoScroll.contentView.bounds.minY - 200) <= 1
                        && presenter.contentController === infoController && infoScroll.documentView === infoDocument
                        && infoWindow.firstResponder === infoResponder && infoWindow.isKeyWindow && NSApp.isActive }) else {
                        print("Info refresh failed: offset=\(infoScroll.contentView.bounds.minY), controller=\(presenter.contentController === infoController), document=\(infoScroll.documentView === infoDocument), responder=\(infoWindow.firstResponder === infoResponder), sameWindow=\(presenter.window === infoWindow), visible=\(infoWindow.isVisible), active=\(NSApp.isActive)")
                        throw MenuCheckError.infoRefreshNotPreserved
                    }
                    records.append(["position": "info-refresh", "offset": infoScroll.contentView.bounds.minY,
                                    "preservesController": true, "preservesDocument": true, "preservesFocus": true,
                                    "dataDrivenContent": true, "concurrentTaskRefresh": true,
                                    "updatedTotal": expectedAmount])
                    if let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: infoWindow.windowNumber, context: nil,
                        characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53) {
                        NSApp.postEvent(escape, atStart: false)
                    }
                    guard await waitForStable({ presenter.shownIdentifier == nil && reopened.isVisible
                        && reopened.isKeyWindow && reopened.firstResponder === info }) else {
                        print("Info Escape failed: dismissed=\(presenter.shownIdentifier == nil), parentVisible=\(reopened.isVisible), triggerAttached=\(info.window === reopened), triggerFocused=\(reopened.firstResponder === info), parentKey=\(reopened.isKeyWindow), infoKey=\(infoWindow.isKeyWindow), active=\(NSApp.isActive), front=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown")")
                        throw MenuCheckError.infoEscapeFocusNotRestored
                    }
                    records.append(["position": "info-popover", "firstEscapeKeepsMenu": true,
                                    "restoresTriggerFocus": true, "nativePopover": true])
                    let control = reopened.contentView.flatMap { menuControl(in: $0) }
                    let focused = control.map { reopened.makeFirstResponder($0) } ?? false
                    let keyboardAppWasActive = NSApp.isActive
                    let keyboardWindowWasKey = reopened.isKeyWindow
                    print("Keyboard fixture: active=\(NSApp.isActive), canKey=\(reopened.canBecomeKey), key=\(reopened.isKeyWindow), control=\(control != nil), focused=\(focused)")
                    guard control != nil, focused else {
                        throw MenuCheckError.keyboardFocusUnavailable
                    }
                    if let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: reopened.windowNumber, context: nil,
                        characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53) {
                        reopened.sendEvent(escape)
                    }
                    guard await waitFor({ !reopened.isVisible }) else { throw MenuCheckError.escapeDidNotClose }
                    guard await waitFor({ NSWorkspace.shared.frontmostApplication?.processIdentifier == previousApplication }) else {
                        throw MenuCheckError.focusNotRestored
                    }
                    records.append(["position": "controls", "toggleAndEscapePassed": true,
                                    "keyboardDispatch": "native-window", "keyboardFirstResponder": "task-disclosure",
                                    "appWasActive": keyboardAppWasActive,
                                    "windowWasKey": keyboardWindowWasKey,
                                    "openedFromBackground": true, "previousApplicationRestored": true,
                                    "forcedRecoveryBaseline": forcedRecovery,
                                    "restoredVisibilityBeforeToggle": restoredVisibilityBeforeToggle])
                    // Pure dsh uses the same native popover and keyboard controls.
                    PreviewSupport.configure(MonitorStore.shared, scenario: .dshOnly)
                    try await Task.sleep(for: .milliseconds(700))
                    let dshPreviousApplication = try await prepareBackgroundMenu(in: directory)
                    toggleMenu?()
                    guard await waitFor({ menuWindow?()?.isVisible == true }),
                          let dshWindow = menuWindow?(), let dshView = dshWindow.contentView,
                          menuControl(in: dshView) != nil,
                          !MonitorStore.shared.showsQuota, MonitorStore.shared.menuTaskCount == "2" else {
                        throw MenuCheckError.invalidDshState
                    }
                    dshView.layoutSubtreeIfNeeded()
                    try PreviewSupport.saveBitmap(dshView, to: directory.appendingPathComponent("dsh-only-layout.png"))
                    guard await waitFor({ NSApp.isActive && dshWindow.isKeyWindow }) else {
                        print("dsh keyboard focus unavailable: active=\(NSApp.isActive), canKey=\(dshWindow.canBecomeKey), key=\(dshWindow.isKeyWindow), visible=\(dshWindow.isVisible)")
                        throw MenuCheckError.keyboardFocusUnavailable
                    }
                    let dshAppWasActive = NSApp.isActive, dshWindowWasKey = dshWindow.isKeyWindow
                    if let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: dshWindow.windowNumber, context: nil,
                        characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53) {
                        dshWindow.sendEvent(escape)
                    }
                    guard await waitFor({ !dshWindow.isVisible }) else { throw MenuCheckError.escapeDidNotClose }
                    guard await waitFor({ NSWorkspace.shared.frontmostApplication?.processIdentifier == dshPreviousApplication }) else {
                        throw MenuCheckError.focusNotRestored
                    }
                    records.append(["position": "dsh-only", "quotaHidden": true,
                                    "runningCount": "2", "escapePassed": true,
                                    "openedFromBackground": true, "previousApplicationRestored": true,
                                    "appWasActive": dshAppWasActive, "windowWasKey": dshWindowWasKey])
                    // Exercise reference costs in the actual NSPopover, including
                    // its native material, contrast and reduced-transparency variants.
                    PreviewSupport.configure(MonitorStore.shared, scenario: .apiCosts)
                    // Cost model rows now live in the explanation. Keep overflow testing
                    // independent of their former inline height with additional safe cards.
                    if let template = MonitorStore.shared.tasks.first {
                        for index in 0..<8 {
                            MonitorStore.shared.tasks.append(TaskSnapshot(id: "cost-scroll-\(index)", title: "Cost scrolling fixture",
                                model: template.model, source: .desktop, parentID: nil, startedAt: template.startedAt,
                                updatedAt: template.updatedAt, tokens: template.tokens, activity: .running,
                                apiCostSource: template.apiCostSource))
                        }
                    }
                    var costPreviousApplication = try await prepareBackgroundMenu(in: directory)
                    toggleMenu?()
                    guard await waitFor({ menuWindow?()?.isVisible == true }),
                          let initialCostWindow = menuWindow?(), let initialCostView = initialCostWindow.contentView else {
                        throw MenuCheckError.timedOut
                    }
                    var costWindow = initialCostWindow, costView = initialCostView
                    guard await waitFor({ NSApp.isActive && costWindow.isKeyWindow }) else {
                        throw MenuCheckError.keyboardFocusUnavailable
                    }
                    try await Task.sleep(for: .milliseconds(400))
                    for id in ["cost-single", "cost-mixed", "cost-dsh", "cost-partial", "cost-unavailable"] {
                        guard let control = menuControl(in: costView, id: "monitor.tokens." + id) else {
                            throw MenuCheckError.missingCostControls
                        }
                        control.performClick(nil)
                    }
                    try await Task.sleep(for: .milliseconds(700))
                    // Expansion changes the popover's geometry. As in the
                    // earlier shrink check, a transient dismissal can occur
                    // while the fixture settles. Reopen the settled content
                    // through the production controller before measuring it.
                    let reopenedAfterLayout = !costWindow.isVisible || !costWindow.isKeyWindow || !NSApp.isActive
                    if reopenedAfterLayout {
                        if menuWindow?()?.isVisible == true { toggleMenu?() }
                        guard await waitFor({ menuWindow?()?.isVisible != true }) else { throw MenuCheckError.didNotClose }
                        costPreviousApplication = try await prepareBackgroundMenu(in: directory)
                        toggleMenu?()
                        guard await waitFor({ menuWindow?()?.isVisible == true }),
                              let reopened = menuWindow?(), let content = reopened.contentView else {
                            throw MenuCheckError.didNotOpen
                        }
                        costWindow = reopened; costView = content
                        guard await waitFor({ NSApp.isActive && costWindow.isKeyWindow }) else {
                            throw MenuCheckError.keyboardFocusUnavailable
                        }
                        try await Task.sleep(for: .milliseconds(150))
                    }
                    for id in ["cost-single", "cost-mixed", "cost-dsh", "cost-partial", "cost-unavailable"] {
                        guard let control = menuControl(in: costView, id: "monitor.tokens." + id),
                              String(describing: control.accessibilityValue() ?? "").contains(L10n.text("Expanded")) else {
                            throw MenuCheckError.missingCostControls
                        }
                    }
                    costView.layoutSubtreeIfNeeded()
                    guard let costScroll = scrollView(in: costView), let costDocument = costScroll.documentView else {
                        throw MenuCheckError.timedOut
                    }
                    let costOverflow = max(0, costDocument.bounds.height - costScroll.contentView.bounds.height)
                    guard costOverflow > 0 else { throw MenuCheckError.expectedOverflow }
                    guard let costSource = MonitorStore.shared.tasks.first(where: { $0.id == "cost-mixed" })?.apiCostSource,
                          case .recorded(let modelEstimate) = costSource, modelEstimate.lines.count >= 12 else {
                        throw MenuCheckError.missingCostControls
                    }
                    let costWindowHeight = costWindow.frame.height
                    var costScrolls: [[String: Any]] = []
                    for (position, offset) in [("top", CGFloat.zero), ("middle", costOverflow / 2), ("bottom", costOverflow)] {
                        costScroll.contentView.scroll(to: NSPoint(x: 0, y: offset))
                        costScroll.reflectScrolledClipView(costScroll.contentView)
                        try await Task.sleep(for: .milliseconds(100))
                        guard costWindow.isVisible, NSApp.isActive, costWindow.isKeyWindow else {
                            throw MenuCheckError.keyboardFocusUnavailable
                        }
                        guard abs(costWindow.frame.height - costWindowHeight) < 1 else { throw MenuCheckError.unstableHeight }
                        let actualOffset = costScroll.contentView.bounds.origin.y
                        guard abs(actualOffset - offset) <= 1 else { throw MenuCheckError.didNotScroll }
                        costScrolls.append(["position": position, "offset": actualOffset,
                                            "windowHeight": costWindow.frame.height])
                        try PreviewSupport.saveBitmap(costView, to: directory.appendingPathComponent("api-cost-" + position + "-layout.png"))
                    }
                    records.append(["position": "api-costs", "expanded": 5, "overflow": costOverflow,
                                    "source": "deterministic-fixtures", "nativePopover": true,
                                    "modelCount": modelEstimate.lines.count, "scrolls": costScrolls,
                                    "reopenedAfterLayout": reopenedAfterLayout,
                                    "appWasActive": NSApp.isActive, "windowWasKey": costWindow.isKeyWindow])
                    print("API cost before close: visible=\(costWindow.isVisible), key=\(costWindow.isKeyWindow), active=\(NSApp.isActive), currentWindow=\(menuWindow?() === costWindow)")
                    toggleMenu?()
                    guard await waitFor({ !costWindow.isVisible
                        && NSWorkspace.shared.frontmostApplication?.processIdentifier == costPreviousApplication }) else {
                        print("API cost after close: visible=\(costWindow.isVisible), key=\(costWindow.isKeyWindow), active=\(NSApp.isActive), frontIsHost=\(NSWorkspace.shared.frontmostApplication?.processIdentifier == costPreviousApplication), currentVisible=\(menuWindow?()?.isVisible == true)")
                        throw MenuCheckError.focusNotRestored
                    }
                    PreviewSupport.configure(MonitorStore.shared, scenario: .noSources)
                    toggleMenu?()
                    try await Task.sleep(for: .milliseconds(700))
                    guard let emptyView = menuWindow?()?.contentView, MonitorStore.shared.noSourcesFound,
                          MonitorStore.shared.menuTaskCount == "0", !MonitorStore.shared.hasSourceWarning else {
                        throw MenuCheckError.invalidDshState
                    }
                    try PreviewSupport.saveBitmap(emptyView, to: directory.appendingPathComponent("no-sources-layout.png"))
                    records.append(["position": "no-sources", "runningCount": "0", "warning": false])
                    try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys])
                        .write(to: directory.appendingPathComponent("menu-check.json"))
                    print("Menu checks passed: top, middle, bottom, rapid scrolling, live shrink. Window \(window.windowNumber)")
                    if CommandLine.arguments.contains("--exit-after-menu-checks"), PreviewSupport.menuScenario != nil {
                        NSApp.terminate(nil)
                    }
                    return
                }
                throw MenuCheckError.timedOut
            } catch {
                print("Menu checks failed: \(error)")
                if CommandLine.arguments.contains("--exit-after-menu-checks"), PreviewSupport.menuScenario != nil { exit(1) }
            }
        }
    }

    private static func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap { scrollView(in: $0) }.first
    }

    private static func menuControl(in view: NSView, id: String? = nil) -> NSButton? {
        if let button = view as? NSButton, button.accessibilityIdentifier().hasPrefix("monitor.tokens."),
           id == nil || button.accessibilityIdentifier() == id { return button }
        return view.subviews.lazy.compactMap { menuControl(in: $0, id: id) }.first
    }

    private static func infoControl(in view: NSView, kind: String) -> TaskInfoNativeButton? {
        if let button = view as? TaskInfoNativeButton,
           button.accessibilityIdentifier().hasPrefix("monitor.info.\(kind).") { return button }
        return view.subviews.lazy.compactMap { infoControl(in: $0, kind: kind) }.first
    }

    private static func waitFor(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<20 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    /// A visible/key flag can change before AppKit finishes its responder work.
    /// Require readiness on separate event-loop turns; keep the existing 1s bound.
    private static func waitForStable(_ condition: () -> Bool) async -> Bool {
        var consecutive = 0
        for _ in 0..<20 {
            consecutive = condition() ? consecutive + 1 : 0
            if consecutive == 2 { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    /// Exercise the actual background-open path instead of inheriting focus
    /// from LaunchServices or a settings preview that ran earlier.
    private static func prepareBackgroundMenu(in directory: URL) async throws -> pid_t {
        let hostReceipt = directory.appendingPathComponent("focus-host/process.json")
        guard let data = try? Data(contentsOf: hostReceipt),
              let receipt = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawPID = receipt["pid"] as? Int,
              let host = NSRunningApplication(processIdentifier: pid_t(rawPID)),
              host.bundleIdentifier?.hasSuffix(".keyboard-focus-host") == true else {
            throw MenuCheckError.backgroundSetupFailed
        }
        let request = UUID().uuidString
        let pid = host.processIdentifier
        print("Keyboard host request: appActive=\(NSApp.isActive), hostActive=\(host.isActive), host=\(pid)")
        // The host owns activation and only acknowledges after its window has
        // settled. Do not issue another activate request after its yield.
        if NSApp.isActive { NSApp.yieldActivation(to: host) }
        try request.write(to: directory.appendingPathComponent("focus-request"), atomically: true, encoding: .utf8)
        guard await waitForStable({
            !NSApp.isActive && host.isActive
                && NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
                && (try? String(contentsOf: directory.appendingPathComponent("focus-ready"), encoding: .utf8)) == request
        }) else {
            print("Keyboard host timeout: appActive=\(NSApp.isActive), hostActive=\(host.isActive), front=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown"), ready=\(FileManager.default.fileExists(atPath: directory.appendingPathComponent("focus-ready").path))")
            throw MenuCheckError.backgroundSetupFailed
        }
        print("Keyboard background fixture: active=\(NSApp.isActive), previous=\(pid), cooperativeYield=true, settledHostBeforeYield=true")
        return pid
    }

    private enum MenuCheckError: Error {
        case missingScrollView, expectedOverflow, unstableHeight, didNotShrink, timedOut
        case missingCostControls
        case didNotScroll
        case didNotClose, didNotOpen, escapeDidNotClose
        case keyboardFocusUnavailable, backgroundSetupFailed, focusNotRestored, invalidDshState, invalidLease, appearanceMismatch
        case infoRefreshNotPreserved, infoEscapeFocusNotRestored
    }

    /// Capture our own real popover, avoiding a fixed preview window that
    /// can hide intrinsic-size regressions. This bitmap checks layout, not live glass;
    /// use the printed window number with macOS screencapture for compositor output.
    static func captureNextMenu(to destination: URL) {
        Task { @MainActor in
            for _ in 0..<150 {
                try? await Task.sleep(for: .milliseconds(200))
                guard let window = menuWindow?(), window.isVisible,
                      let view = window.contentView else { continue }
                try? await Task.sleep(for: .milliseconds(600))
                view.layoutSubtreeIfNeeded()
                let description = "Menu window: \(window.windowNumber), size: \(window.frame.size), screen: \(window.screen.map { String(describing: $0.visibleFrame) } ?? "unknown")\n"
                FileHandle.standardOutput.write(Data(description.utf8))
                if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    if let data = bitmap.representation(using: .png, properties: [:]) {
                        try? data.write(to: destination)
                    }
                }
                return
            }
            print("Menu capture timed out. Open the Veyra menu within 30 seconds.")
        }
    }

    /// Opt-in, local integration check. Omits credentials, email, titles and transcript content.
    static func run() {
        MonitorStore.shared.isPreview = true
        Task {
            let location = MonitorStore.shared.location
            let client = AppServerClient(), reader = LocalTaskReader()
            let clock = ContinuousClock(), start = clock.now
            do {
                let initial = try await reader.fetch(home: location.home)
                let firstDuration = start.duration(to: clock.now)
                let secondStart = clock.now
                let incremental = try await reader.fetch(home: location.home)
                let secondDuration = secondStart.duration(to: clock.now)
                let quota = CommandLine.arguments.contains("--network")
                    ? await client.fetch(location: location) : QuotaRefresh()
                let result: [String: JSONValue] = [
                    "energyBenchmarkIsolation": .bool(CommandLine.arguments.contains("--energy-benchmark")),
                    "quotaError": quota.error.map { .string($0.message) } ?? .null,
                    "quotaErrorCode": quota.error.map { .string($0.rawValue) } ?? .null,
                    "taskWarning": initial.warning.map { .string($0.message) } ?? .null,
                    "initialRead": .string(String(describing: firstDuration)),
                    "incrementalRead": .string(String(describing: secondDuration)),
                    "quotaSource": quota.snapshot.map { _ in .string("network") } ?? .null,
                    "metadataQueries": .number(Double(incremental.metrics.metadataQueries)),
                    "historyQueries": .number(Double(incremental.metrics.historyQueries)),
                    "rolloutBytes": .number(Double(incremental.metrics.rolloutBytes)),
                    "rolloutOpens": .number(Double(incremental.metrics.rolloutOpens)),
                    "quotaHTTPStatus": quota.failureDetails?.httpStatus.map { .number(Double($0)) } ?? .null,
                    "quotaRetryAfterSeconds": quota.failureDetails?.retryAfter.map(JSONValue.number) ?? .null,
                    "windows": .array((quota.snapshot?.windows ?? []).map { .object([
                        "bucket": .string($0.bucketID), "window": .string($0.durationLabel),
                        "remainingPercent": $0.remainingPercent.map(JSONValue.number) ?? .null
                    ]) }),
                    "tasks": .array(incremental.tasks.map { .object([
                        "id": .string($0.id), "activity": .string($0.activity.rawValue),
                        "model": $0.model.map(JSONValue.string) ?? .null,
                        "totalTokens": $0.tokens.total.map { .number(Double($0)) } ?? .null,
                        "inputTokens": $0.tokens.input.map { .number(Double($0)) } ?? .null,
                        "outputTokens": $0.tokens.output.map { .number(Double($0)) } ?? .null
                    ]) })
                ]
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                let data = try encoder.encode(JSONValue.object(result))
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data("\n".utf8))
            } catch { print(L10n.text("Diagnostics failed: unable to complete local diagnostics.")) }
            await client.shutdown()
            NSApp.terminate(nil)
        }
    }
}
