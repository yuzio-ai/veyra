import SwiftUI
import AppKit

/// Deterministic render fixtures, only selected by an explicit developer command-line argument.
@MainActor
enum PreviewSupport {
    private static var retainedWindow: NSWindow?

    static func render(to directory: URL) {
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch { NSApp.terminate(nil); return }
        let store = MonitorStore.shared
        store.isPreview = true
        let now = Date()
        let raw: JSONValue = .object(["rateLimits": .object([
            "limitId": .string("codex"), "primary": .object([
                "usedPercent": .number(48), "windowDurationMins": .number(10080), "resetsAt": .number(now.addingTimeInterval(86_400 * 3).timeIntervalSince1970)
            ])
        ])])
        store.quota.snapshot = QuotaSnapshot.parse(raw)
        store.quota.account = AccountSnapshot(json: .object(["type": .string("chatgpt"), "planType": .string("pro")]))
        store.tasks = [
            TaskSnapshot(id: "demo-1", title: "构建 SwiftUI 菜单栏应用", model: "gpt-5.6-sol", sourceLabel: "桌面端", parentID: nil,
                         startedAt: now.addingTimeInterval(-752), updatedAt: now,
                         tokens: TokenUsage(input: 232108, output: 6892, cachedInput: 198400, reasoningOutput: 2891, total: 239000), activity: .running),
            TaskSnapshot(id: "demo-2", title: "检查额度读取与并行任务监控，验证非常长的任务名称能够正确换行并保持界面整齐", model: "gpt-5.6-terra", sourceLabel: "子任务", parentID: "demo-1",
                         startedAt: now.addingTimeInterval(-168), updatedAt: now,
                         tokens: TokenUsage(input: 84700, output: 4600, cachedInput: 72000, reasoningOutput: 1200, total: 89300), activity: .running)
        ]
        store.tasksUpdatedAt = now
        // WindowServer composites live glass. Bitmap exports instead use the
        // supported Reduce Transparency appearance to verify text and layout.
        let hosting = NSHostingView(rootView: MonitorPanel(store: store)
            .environment(\.monitorOpaquePreview, true))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 660), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        window.setContentSize(NSSize(width: 420, height: hosting.fittingSize.height))
        window.orderFront(nil)
        retainedWindow = window
        Task { @MainActor in
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
                window.appearance = NSAppearance(named: appearance)
                try? await Task.sleep(for: .milliseconds(700))
                hosting.layoutSubtreeIfNeeded()
                if let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
                    hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                    if let png = bitmap.representation(using: .png, properties: [:]) {
                        try? png.write(to: directory.appendingPathComponent("\(name).png"))
                    }
                }
            }
            store.tasks = []
            try? await Task.sleep(for: .milliseconds(500))
            if let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("empty.png"))
            }
            NSApp.terminate(nil)
        }
    }
}
