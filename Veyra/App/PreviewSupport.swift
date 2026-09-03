import SwiftUI
import AppKit

/// Deterministic fixtures, selected only by explicit developer command-line arguments.
@MainActor
enum PreviewSupport {
    enum Scenario: String, CaseIterable {
        case loading, empty, single, longTitle = "long-title", multiple, quotas, error, expanded, unknown
        case edgeCases = "edge-cases"
        case localQuota = "local-quota", staleQuota = "stale-quota", noQuota = "no-quota", cooldown
    }

    static let referenceDate = Date(timeIntervalSince1970: 1_788_410_400)
    private static var retainedWindow: NSWindow?

    static var menuScenario: Scenario? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--preview-menu"), arguments.indices.contains(index + 1) else { return nil }
        return Scenario(rawValue: arguments[index + 1])
    }

    static var menuAppearance: NSAppearance.Name? {
        let arguments = CommandLine.arguments
        guard menuScenario != nil, let index = arguments.firstIndex(of: "--preview-appearance"),
              arguments.indices.contains(index + 1) else { return nil }
        return ["light": .aqua, "dark": .darkAqua,
                "light-increased": .accessibilityHighContrastAqua,
                "dark-increased": .accessibilityHighContrastDarkAqua][arguments[index + 1]]
    }
    static var menuIncreasedContrast: Bool {
        menuAppearance == .accessibilityHighContrastAqua || menuAppearance == .accessibilityHighContrastDarkAqua
    }
    static var menuReduceTransparency: Bool {
        menuScenario != nil && CommandLine.arguments.contains("--preview-reduce-transparency")
    }

    static func configure(_ store: MonitorStore, scenario: Scenario) {
        store.isPreview = true
        store.quota = QuotaDisplayState()
        store.taskError = nil
        store.taskWarning = nil
        store.tasksBusy = false
        store.quotaBusy = false
        store.nextCalibrationAt = nil
        store.localQuotaWarning = nil
        store.tasksUpdatedAt = referenceDate
        store.tasks = []
        if scenario == .loading {
            store.tasksUpdatedAt = nil
            store.tasksBusy = true
            store.quotaBusy = true
            return
        }
        store.quota.account = AccountSnapshot(json: .object([
            "type": .string("chatgpt"), "planType": .string("pro"), "email": .string("preview@example.invalid")
        ]))
        var windows = [quota("codex", "Codex", primary: true, used: 52, minutes: 10_080)]
        if [.quotas, .multiple, .expanded].contains(scenario) {
            windows += [quota("spark", "GPT-5.3-Codex-Spark", primary: true, used: 0, minutes: 300),
                        quota("spark", "GPT-5.3-Codex-Spark", primary: false, used: 78, minutes: 10_080)]
        }
        if scenario == .error {
            windows = [quota("codex", "Codex", primary: true, used: 94, minutes: 300)]
            store.quota.error = QuotaFailure.rpcFailed.message
            store.taskError = "无法读取本机任务记录，请在设置中检查数据目录。"
        }
        if scenario == .edgeCases {
            windows = [
                QuotaWindow(id: "codex:primary", bucketID: "codex", bucketName: "Codex", isPrimary: true,
                            usedPercent: 99.6, durationMinutes: 10_080,
                            resetsAt: referenceDate.addingTimeInterval(-60)),
                QuotaWindow(id: "codex:secondary", bucketID: "codex", bucketName: "Codex", isPrimary: false,
                            usedPercent: nil, durationMinutes: nil, resetsAt: nil)
            ]
        }
        store.quota.snapshot = QuotaSnapshot(windows: windows, fetchedAt: referenceDate, accountID: nil)
        if [.localQuota, .staleQuota].contains(scenario) {
            store.quota.account = nil
            store.quota.snapshot = QuotaSnapshot(windows: windows,
                fetchedAt: referenceDate.addingTimeInterval(scenario == .staleQuota ? -600 : 0),
                accountID: nil, source: .local)
        }
        if scenario == .noQuota { store.quota = QuotaDisplayState() }
        if scenario == .cooldown {
            store.quota.error = QuotaFailure.rateLimited.message
            store.nextCalibrationAt = referenceDate.addingTimeInterval(300)
        }
        switch scenario {
        case .single, .quotas, .expanded, .localQuota, .staleQuota, .cooldown:
            store.tasks = [task(1)]
        case .longTitle:
            store.tasks = [task(1, longTitle: true)]
        case .multiple:
            store.tasks = (1...16).map { task($0, longTitle: $0 == 2 || $0 == 4, parentID: $0 == 2 ? "demo-1" : nil) }
        case .unknown:
            store.tasks = [task(1), task(2, longTitle: true, activity: .unknown)]
        case .edgeCases:
            store.tasks = [
                TaskSnapshot(id: "demo-1", title: "检查长数值换行、缺失数据与已经到期的额度窗口，保持所有摘要可读",
                             model: "a-long-model-name-for-layout-validation", sourceLabel: "桌面端", parentID: nil,
                             startedAt: referenceDate.addingTimeInterval(-9_876_543), updatedAt: referenceDate,
                             tokens: TokenUsage(input: Int64.max / 2, output: Int64.max / 2, total: Int64.max - 1),
                             activity: .running),
                TaskSnapshot(id: "demo-2", title: "缺失用量与开始时间的子任务", model: nil, sourceLabel: "子任务",
                             parentID: "demo-1", startedAt: nil, updatedAt: referenceDate,
                             tokens: TokenUsage(), activity: .running)
            ]
        case .loading, .empty, .error, .noQuota:
            break
        }
    }

    private static func quota(_ id: String, _ name: String, primary: Bool, used: Double, minutes: Int64) -> QuotaWindow {
        QuotaWindow(id: "\(id):\(primary ? "primary" : "secondary")", bucketID: id, bucketName: name,
                    isPrimary: primary, usedPercent: used, durationMinutes: minutes,
                    resetsAt: referenceDate.addingTimeInterval(Double(minutes * 60)))
    }

    private static func task(_ number: Int, longTitle: Bool = false, parentID: String? = nil,
                             activity: TaskActivity = .running) -> TaskSnapshot {
        TaskSnapshot(id: "demo-\(number)",
                     title: longTitle ? "检查额度读取与并行任务监控，验证非常长的任务名称能够正确换行并保持界面整齐" : "优化菜单栏弹窗与滚动体验 · \(number)",
                     model: "gpt-5.6-sol", sourceLabel: parentID == nil ? "桌面端" : "子任务", parentID: parentID,
                     startedAt: referenceDate.addingTimeInterval(-752), updatedAt: referenceDate,
                     tokens: TokenUsage(input: 877_208, output: 6_892, cachedInput: 698_400, reasoningOutput: 2_891, total: 884_100),
                     activity: activity)
    }

    private static func panel(store: MonitorStore, scenario: Scenario, screenHeight: CGFloat = 800, increasedContrast: Bool = false,
                              onSizingChange: @escaping (PanelSizing) -> Void) -> some View {
        MonitorPanel(store: store, screenOverride: PanelScreenMetrics(visibleHeight: screenHeight),
                     initiallyExpandedTaskIDs: scenario == .expanded ? ["demo-1"] : [],
                     initiallyShowUnknown: scenario == .unknown, onSizingChange: onSizingChange)
            .environment(\.monitorOpaquePreview, true)
            .environment(\.monitorPreviewContrast, increasedContrast ? .increased : .standard)
            .environment(\.monitorReferenceDate, referenceDate)
    }

    static func render(to directory: URL) {
        Task { @MainActor in
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let store = MonitorStore()
                var results: [[String: Any]] = []
                for scenario in Scenario.allCases {
                    configure(store, scenario: scenario)
                    let appearances: [(String, NSAppearance.Name)] = [
                        ("light", .aqua), ("dark", .darkAqua),
                        ("light-increased", .accessibilityHighContrastAqua),
                        ("dark-increased", .accessibilityHighContrastDarkAqua)
                    ]
                    for (name, appearance) in appearances {
                        var measured: PanelSizing?
                        let hosting = NSHostingView(rootView: panel(store: store, scenario: scenario,
                            increasedContrast: name.hasSuffix("increased")) { measured = $0 })
                        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: PanelSizing.width, height: 1),
                                              styleMask: [.borderless], backing: .buffered, defer: false)
                        window.appearance = NSAppearance(named: appearance)
                        window.contentView = hosting
                        window.setFrameTopLeftPoint(NSPoint(x: 60, y: 900))
                        window.orderFront(nil)
                        retainedWindow = window
                        // Let the single real tree measure, then let the host adopt its ideal size.
                        for _ in 0..<5 {
                            try await Task.sleep(for: .milliseconds(80))
                            hosting.layoutSubtreeIfNeeded()
                            window.setContentSize(NSSize(width: PanelSizing.width, height: hosting.fittingSize.height))
                        }
                        guard let measured, measured.contentHeight > 1,
                              abs(hosting.bounds.height - measured.panelHeight) <= 2,
                              abs(hosting.bounds.width - PanelSizing.width) < 1 else {
                            throw PreviewError.invalidLayout("\(scenario.rawValue)-\(name)")
                        }
                        // Layout regression budgets for these fixed fixtures only;
                        // Include the source timestamp and explicit calibration controls;
                        // production height always comes from the actual content.
                        let heightBudget: CGFloat = scenario == .single ? 560 : scenario == .quotas ? 730 : 776
                        guard measured.panelHeight <= heightBudget else {
                            throw PreviewError.invalidLayout("\(scenario.rawValue)-\(name): \(measured.panelHeight) exceeds \(heightBudget)")
                        }
                        let filename = "\(scenario.rawValue)-\(name)"
                        try saveBitmap(hosting, to: directory.appendingPathComponent(filename + ".png"))
                        results.append(["name": filename, "width": hosting.bounds.width,
                                        "height": hosting.bounds.height, "contentHeight": measured.contentHeight,
                                        "viewportHeight": measured.viewportHeight, "scrollable": measured.isScrollable])
                        window.orderOut(nil)
                        retainedWindow = nil
                    }
                }
                try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
                    .write(to: directory.appendingPathComponent("layouts.json"))
                print("Rendered \(results.count) layout previews to \(directory.path)")
                NSApp.terminate(nil)
            } catch {
                FileHandle.standardError.write(Data("Preview failed: \(error)\n".utf8))
                exit(1)
            }
        }
    }

    static func saveBitmap(_ view: NSView, to destination: URL) throws {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw PreviewError.invalidLayout(destination.lastPathComponent)
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw PreviewError.invalidLayout(destination.lastPathComponent)
        }
        try data.write(to: destination)
    }

    private enum PreviewError: Error { case invalidLayout(String) }
}
