import Foundation
import AppKit

@MainActor
enum Diagnostics {
    /// Opt-in interaction smoke test against the actual menu window, not a substitute window.
    /// Images remain layout-only; this never requests screen recording permission.
    static func exerciseNextMenu(to directory: URL) {
        Task { @MainActor in
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                for _ in 0..<300 {
                    try await Task.sleep(for: .milliseconds(200))
                    guard let window = NSApp.windows.first(where: {
                        $0.isVisible && abs($0.frame.width - PanelSizing.width) < 4 && $0.frame.height > 100
                    }), let view = window.contentView else { continue }
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
                    try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys])
                        .write(to: directory.appendingPathComponent("menu-check.json"))
                    print("Menu checks passed: top, middle, bottom, rapid scrolling, live shrink. Window \(window.windowNumber)")
                    return
                }
                throw MenuCheckError.timedOut
            } catch {
                print("Menu checks failed: \(error)")
            }
        }
    }

    private static func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap { scrollView(in: $0) }.first
    }

    private enum MenuCheckError: Error {
        case missingScrollView, expectedOverflow, unstableHeight, didNotShrink, timedOut
    }

    /// Capture our own real MenuBarExtra, avoiding a fixed preview window that
    /// can hide intrinsic-size regressions. This bitmap checks layout, not live glass;
    /// use the printed window number with macOS screencapture for compositor output.
    static func captureNextMenu(to destination: URL) {
        Task { @MainActor in
            for _ in 0..<150 {
                try? await Task.sleep(for: .milliseconds(200))
                guard let window = NSApp.windows.first(where: {
                    $0.isVisible && abs($0.frame.width - PanelSizing.width) < 4 && $0.frame.height > 100
                }), let view = window.contentView else { continue }
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
                    ? await client.fetch(location: location) : QuotaRefresh(snapshot: incremental.localQuota)
                let result: [String: JSONValue] = [
                    "quotaError": quota.error.map { .string($0.message) } ?? .null,
                    "quotaErrorCode": quota.error.map { .string($0.rawValue) } ?? .null,
                    "taskWarning": initial.warning.map { .string($0.message) } ?? .null,
                    "initialRead": .string(String(describing: firstDuration)),
                    "incrementalRead": .string(String(describing: secondDuration)),
                    "quotaSource": quota.snapshot.map { .string($0.source.rawValue) } ?? .null,
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
