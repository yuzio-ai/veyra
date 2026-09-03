import Foundation
import AppKit

@MainActor
enum Diagnostics {
    /// Capture our own real MenuBarExtra, avoiding a fixed preview window that
    /// can hide intrinsic-size regressions. Only enabled by this explicit flag.
    static func captureNextMenu(to destination: URL) {
        Task { @MainActor in
            for _ in 0..<150 {
                try? await Task.sleep(for: .milliseconds(200))
                guard let window = NSApp.windows.first(where: {
                    $0.isVisible && abs($0.frame.width - 420) < 4 && $0.frame.height > 200
                }), let view = window.contentView else { continue }
                try? await Task.sleep(for: .milliseconds(600))
                view.layoutSubtreeIfNeeded()
                if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    if let data = bitmap.representation(using: .png, properties: [:]) {
                        try? data.write(to: destination)
                    }
                }
                return
            }
        }
    }

    /// Opt-in, local integration check. Omits credentials, email, titles and transcript content.
    static func run() {
        MonitorStore.shared.isPreview = true
        Task {
            let location = MonitorStore.shared.location
            let client = AppServerClient(), reader = LocalTaskReader()
            let clock = ContinuousClock(), start = clock.now
            async let quotaRead = client.fetch(location: location)
            do {
                let initial = try await reader.fetch(home: location.home)
                let firstDuration = start.duration(to: clock.now)
                let secondStart = clock.now
                let incremental = try await reader.fetch(home: location.home)
                let secondDuration = secondStart.duration(to: clock.now)
                let quota = await quotaRead
                let result: [String: JSONValue] = [
                    "quotaError": quota.error.map(JSONValue.string) ?? .null,
                    "taskWarning": initial.warning.map(JSONValue.string) ?? .null,
                    "initialRead": .string(String(describing: firstDuration)),
                    "incrementalRead": .string(String(describing: secondDuration)),
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
            } catch { print("Diagnostics failed: \(error.localizedDescription)") }
            await client.shutdown()
            NSApp.terminate(nil)
        }
    }
}
