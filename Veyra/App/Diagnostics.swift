import Foundation
import AppKit

@MainActor
enum Diagnostics {
    static var menuWindow: (() -> NSWindow?)?
    static var toggleMenu: (() -> Void)?

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
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                for _ in 0..<300 {
                    try await Task.sleep(for: .milliseconds(200))
                    guard let window = menuWindow?(), window.isVisible,
                          let view = window.contentView else { continue }
                    try await Task.sleep(for: .milliseconds(700))
                    guard let scroll = scrollView(in: view), let document = scroll.documentView else {
                        throw MenuCheckError.missingScrollView
                    }
                    var records: [[String: Any]] = []
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
                    // A transient popover can be dismissed by a foreground-app change during
                    // the asynchronous layout checks. Establish the shown baseline before
                    // testing toggle-to-close, otherwise toggle would reopen it instead.
                    let restoredVisibilityBeforeToggle = !window.isVisible
                    if restoredVisibilityBeforeToggle {
                        print("Fixture dismissed before toggle check; restoring the shown baseline")
                        toggleMenu?()
                        guard await waitFor({ menuWindow?()?.isVisible == true }) else { throw MenuCheckError.didNotOpen }
                    }
                    guard let closing = menuWindow?(), closing.isVisible else { throw MenuCheckError.didNotOpen }
                    // Exercise the same controller used by the registered hotkey and status button.
                    toggleMenu?()
                    guard await waitFor({ !closing.isVisible }) else { throw MenuCheckError.didNotClose }
                    let previousApplication = try await prepareBackgroundMenu(in: directory)
                    toggleMenu?()
                    guard await waitFor({ menuWindow?()?.isVisible == true }) else { throw MenuCheckError.didNotOpen }
                    guard let reopened = menuWindow?(), reopened.isVisible else { throw MenuCheckError.didNotOpen }
                    // LaunchServices brings the fixed fixture to the foreground. Require a real
                    // key window before dispatching a synthetic event through its responder chain.
                    guard await waitFor({ NSApp.isActive && reopened.isKeyWindow }) else {
                        print("Keyboard focus unavailable: app=\(ProcessInfo.processInfo.processIdentifier), front=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1), active=\(NSApp.isActive), policy=\(NSApp.activationPolicy().rawValue), canKey=\(reopened.canBecomeKey), key=\(reopened.isKeyWindow), visible=\(reopened.isVisible), appKey=\(NSApp.keyWindow?.windowNumber ?? -1), popover=\(reopened.windowNumber)")
                        throw MenuCheckError.keyboardFocusUnavailable
                    }
                    let provider = reopened.contentView.flatMap { providerButton(in: $0) }
                    let focused = provider.map { reopened.makeFirstResponder($0) } ?? false
                    let keyboardAppWasActive = NSApp.isActive
                    let keyboardWindowWasKey = reopened.isKeyWindow
                    print("Keyboard fixture: active=\(NSApp.isActive), canKey=\(reopened.canBecomeKey), key=\(reopened.isKeyWindow), provider=\(provider != nil), focused=\(focused)")
                    guard provider != nil, focused else {
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
                                    "keyboardDispatch": "native-window", "keyboardFirstResponder": "provider-button",
                                    "appWasActive": keyboardAppWasActive,
                                    "windowWasKey": keyboardWindowWasKey,
                                    "openedFromBackground": true, "previousApplicationRestored": true,
                                    "restoredVisibilityBeforeToggle": restoredVisibilityBeforeToggle])
                    // Pure dsh uses the same native popover, with no Codex provider control.
                    PreviewSupport.configure(MonitorStore.shared, scenario: .dshOnly)
                    try await Task.sleep(for: .milliseconds(700))
                    let dshPreviousApplication = try await prepareBackgroundMenu(in: directory)
                    toggleMenu?()
                    guard await waitFor({ menuWindow?()?.isVisible == true }),
                          let dshWindow = menuWindow?(), let dshView = dshWindow.contentView,
                          providerButton(in: dshView) == nil,
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
                    records.append(["position": "dsh-only", "providerHidden": true, "quotaHidden": true,
                                    "runningCount": "2", "escapePassed": true,
                                    "openedFromBackground": true, "previousApplicationRestored": true,
                                    "appWasActive": dshAppWasActive, "windowWasKey": dshWindowWasKey])
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

    private static func providerButton(in view: NSView) -> NSButton? {
        if let button = view as? NSButton, button.accessibilityIdentifier() == "models.quickSwitch" { return button }
        return view.subviews.lazy.compactMap { providerButton(in: $0) }.first
    }

    private static func waitFor(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<20 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
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
        try request.write(to: directory.appendingPathComponent("focus-request"), atomically: true, encoding: .utf8)
        NSApp.yieldActivation(to: host)
        host.activate(options: [])
        guard await waitFor({
            !NSApp.isActive && host.isActive
                && (try? String(contentsOf: directory.appendingPathComponent("focus-ready"), encoding: .utf8)) == request
        }) else {
            print("Keyboard host timeout: appActive=\(NSApp.isActive), hostActive=\(host.isActive), ready=\(FileManager.default.fileExists(atPath: directory.appendingPathComponent("focus-ready").path))")
            throw MenuCheckError.backgroundSetupFailed
        }
        print("Keyboard background fixture: active=\(NSApp.isActive), previous=\(pid), cooperativeYield=true")
        return pid
    }

    private enum MenuCheckError: Error {
        case missingScrollView, expectedOverflow, unstableHeight, didNotShrink, timedOut
        case didNotClose, didNotOpen, escapeDidNotClose
        case keyboardFocusUnavailable, backgroundSetupFailed, focusNotRestored, invalidDshState, invalidLease
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
