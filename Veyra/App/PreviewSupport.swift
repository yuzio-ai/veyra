import SwiftUI
import AppKit

/// Deterministic fixtures, selected only by explicit developer command-line arguments.
@MainActor
enum PreviewSupport {
    typealias Scenario = AppArguments.MenuScenario

    enum SettingsScenario: String, CaseIterable {
        case automatic, manual, detecting, missing, invalidDirectory, invalidExecutable, invalidDraft, longPath
    }

    static func settingsStore(_ scenario: SettingsScenario) -> MonitorStore {
        let home = URL(fileURLWithPath: "/Users/preview/.codex")
        let executable = URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex")
        let state: CodexConfigurationState
        switch scenario {
        case .detecting: state = .detecting
        case .missing: state = .notFound
        case .invalidDirectory: state = .invalid(.home)
        case .invalidExecutable: state = .invalid(.executable)
        default: state = .valid
        }
        let location = CodexLocation(home: home, executable: (scenario == .missing) ? nil : executable)
        let store = MonitorStore(defaults: UserDefaults(suiteName: "veyra-settings-preview")!,
                                 inspectConfiguration: { _, _ in CodexConfigurationReport(location: location, state: state) })
        store.isPreview = true
        store.previewCodexServicesAvailable = !(scenario == .missing)
        store.dshHomePath = "/Users/preview/.dsh"
        store.dshReadState = .available
        store.homePath = ""
        store.executablePath = ""
        if [.manual, .invalidDirectory, .invalidExecutable, .longPath].contains(scenario) {
            store.homePath = home.path
            store.executablePath = scenario == .longPath
                ? "/Users/preview/Library/Application Support/" + String(repeating: "Long Installation Directory/", count: 8) + "Resources/codex"
                : executable.path
        }
        return store
    }

    private static func settingsFields(in view: NSView) -> [NSTextField] {
        (view as? NSTextField).map { $0.isEditable ? [$0] : [] } ?? view.subviews.flatMap { settingsFields(in: $0) }
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
        guard let appearance = AppArguments.PreviewAppearance(rawValue: arguments[index + 1]) else { return nil }
        return switch appearance {
        case .light: .aqua
        case .dark: .darkAqua
        case .lightIncreased: .accessibilityHighContrastAqua
        case .darkIncreased: .accessibilityHighContrastDarkAqua
        }
    }
    static var menuIncreasedContrast: Bool {
        menuAppearance == .accessibilityHighContrastAqua || menuAppearance == .accessibilityHighContrastDarkAqua
    }
    static var menuReduceTransparency: Bool {
        menuScenario != nil && CommandLine.arguments.contains("--preview-reduce-transparency")
    }

    static func expandedTaskIDs(for scenario: Scenario?) -> Set<String> {
        switch scenario {
        case .expanded: ["demo-1"]
        case .familyExpanded: ["demo-1", "demo-2"]
        case .tokenBreakdown: ["token-parent", "token-child", "token-deep"]
        case .tokenEdges: ["token-zero", "token-missing", "token-invalid"]
        case .apiCosts: ["cost-single", "cost-mixed", "cost-dsh", "cost-partial", "cost-unavailable"]
        case .edgeCases: ["demo-1", "demo-2"]
        case .dshOnly: ["dsh:demo-1"]
        default: []
        }
    }

    static func configure(_ store: MonitorStore, scenario: Scenario) {
        store.isPreview = true
        store.quota = QuotaDisplayState()
        store.taskError = nil
        store.taskWarning = nil
        store.dshWarning = nil
        store.previewCodexServicesAvailable = true
        store.codexReadState = .available
        store.dshReadState = .notFound
        store.tasksBusy = false
        store.quotaBusy = false
        store.nextCalibrationAt = nil
        store.tasksUpdatedAt = referenceDate
        store.tasks = []
        store.taskAncestors = []
        if [.dshOnly, .dshIdle, .dshUnknown, .dshError, .noSources, .mixedError].contains(scenario) {
            store.previewCodexServicesAvailable = false
            store.codexReadState = .notFound
            store.dshReadState = .available
            switch scenario {
            case .dshOnly: store.tasks = [dshTask(1), dshTask(2)]
            case .dshUnknown: store.tasks = [dshTask(1, activity: .unknown)]
            case .dshError:
                store.dshReadState = .failed
                store.dshWarning = L10n.text("Unable to read dsh session records. Check its data directory.")
            case .noSources: store.dshReadState = .notFound; store.tasksUpdatedAt = nil
            case .mixedError:
                store.tasks = [dshTask(1)]
                store.codexReadState = .failed
                store.taskError = L10n.text("Unable to read Codex task records. Check its data directory.")
            default: break
            }
            return
        }
        if scenario == .loading {
            store.tasksUpdatedAt = nil
            store.tasksBusy = true
            store.quotaBusy = true
            return
        }
        let plan: String
        switch scenario {
        case .planProLite: plan = "prolite"
        case .planBusiness: plan = "self_serve_business_prolite"
        case .planEnterprise: plan = "business"
        case .planUnknown: plan = "future_enterprise_subscription_with_a_very_long_unknown_tier"
        default: plan = "pro"
        }
        store.quota.account = AccountSnapshot(json: .object([
            "type": .string("chatgpt"), "planType": .string(plan), "email": .string("preview@example.invalid")
        ]))
        var windows = [quota("codex", "Codex", primary: true, used: 52, minutes: 10_080)]
        if [.quotas, .multiple, .expanded].contains(scenario) {
            windows = [quota("codex", "Codex", primary: true, used: 52, minutes: 300),
                       quota("codex", "Codex", primary: false, used: 97, minutes: 10_080),
                       quota("additional-limit", "Additional quota", primary: true, used: 0, minutes: 300),
                        quota("additional-limit", "Additional quota", primary: false, used: 78, minutes: 10_080)]
        }
        if scenario == .error {
            windows = [quota("codex", "Codex", primary: true, used: 94, minutes: 300)]
            store.quota.error = QuotaFailure.rpcFailed.message
            store.taskError = L10n.text("Unable to read Codex task records. Check its data directory.")
            store.dshWarning = L10n.text("Some dsh session records are unreadable.")
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
        if scenario == .quotaRingLow || scenario == .quotaRingHigh {
            let remainingValues: [Double?] = scenario == .quotaRingLow ? [0, 0.4, 9.9, 10] : [29.9, 30, 100, nil]
            windows = remainingValues.enumerated().map { index, remaining in
                QuotaWindow(id: "codex:ring-\(index)", bucketID: "codex", bucketName: "Codex",
                            isPrimary: index == 0, usedPercent: remaining.map { 100 - $0 },
                            durationMinutes: Int64((index + 1) * 60),
                            resetsAt: referenceDate.addingTimeInterval(Double((index + 1) * 3_600)))
            }
        }
        store.quota.snapshot = QuotaSnapshot(windows: windows, fetchedAt: referenceDate, accountID: nil)
        if scenario.rawValue.hasPrefix("reset-credits") {
            var entries: [JSONValue] = [resetCredit(after: 86_400), resetCredit(after: 86_400), resetCredit(after: 604_800)]
            var count = 3
            if scenario == .resetCreditsExpired { entries[0] = resetCredit(after: -1) }
            if scenario == .resetCreditsUnknown {
                entries = [resetCredit(after: 86_400), .object(["status": .string("available")])]
                count = 4
            }
            if scenario == .resetCreditsZero { entries = []; count = 0 }
            if scenario == .resetCreditsOverflow {
                entries = (1...96).map { resetCredit(after: Double($0) * 86_400) }
                count = entries.count
            }
            let raw: JSONValue = scenario == .resetCreditsUnavailable ? .null : .object([
                "availableCount": .number(Double(count)), "credits": .array(entries)
            ])
            let snapshot = QuotaSnapshot(windows: scenario == .resetCreditsOnly ? [] : windows,
                fetchedAt: referenceDate, accountID: nil,
                resetCredits: ResetCreditsSnapshot.parse(raw, at: referenceDate))
            store.quota.apply(QuotaRefresh(account: store.quota.account, snapshot: snapshot))
        }
        if scenario == .noQuota { store.quota = QuotaDisplayState() }
        if scenario == .cooldown {
            store.quota.error = QuotaFailure.rateLimited.message
            store.nextCalibrationAt = referenceDate.addingTimeInterval(300)
        }
        switch scenario {
        case .single, .quotas, .expanded, .cooldown, .refreshing:
            store.tasks = [task(1)]
            if scenario == .refreshing { store.tasksBusy = true }
        case .longTitle:
            store.tasks = [task(1, longTitle: true)]
        case .multiple, .taskProjects, .updateAvailable, .planProLite, .planBusiness, .planEnterprise, .planUnknown:
            store.tasks = (1...16).map { task($0, longTitle: $0 == 2 || $0 == 4, parentID: $0 == 2 ? "demo-1" : nil) }
            if scenario == .multiple || scenario == .taskProjects {
                store.tasks += [dshTask(17), dshTask(18, activity: .unknown)]
            }
        case .unknown:
            store.tasks = [task(1), task(2, longTitle: true, activity: .unknown)]
        case .edgeCases:
            store.tasks = [
                TaskSnapshot(id: "demo-1", title: "检查长数值换行、缺失数据与已经到期的额度窗口，保持所有摘要可读",
                             model: "a-long-model-name-for-layout-validation", source: .desktop, parentID: nil,
                             startedAt: referenceDate.addingTimeInterval(-9_876_543), updatedAt: referenceDate,
                             tokens: TokenUsage(input: Int64.max / 2, output: Int64.max / 2, total: Int64.max - 1),
                             activity: .running),
                TaskSnapshot(id: "demo-2", title: "缺失用量与开始时间的子任务", model: nil, source: .subtask,
                             parentID: "demo-1", startedAt: nil, updatedAt: referenceDate,
                             tokens: TokenUsage(), activity: .running)
            ]
        case .apiCosts:
            let screenshot = TokenUsage(input: 250_229, output: 1_404, cachedInput: 211_840, reasoningOutput: 420, total: 251_633)
            let million = TokenUsage(input: 1_000_000, output: 0, cachedInput: 0, total: 1_000_000)
            var single = TaskAPICostEstimate()
            single.add(TaskCostTokens(usage: screenshot)!, model: "gpt-6.1-sol", backend: .codex)
            var mixed = TaskAPICostEstimate()
            let mixedModels = ["gpt-6.1-sol", "gpt-6.1-terra", "gpt-6-astra", "gpt-6-luna", "gpt-6-sol",
                               "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-5.5", "gpt-5.4",
                               "gpt-5.4-mini", "gpt-5.4-nano"]
            for model in mixedModels {
                mixed.add(TaskCostTokens(usage: million)!, model: model, backend: .codex)
            }
            var partial = single
            partial.note(.unknownModel("unpriced-fixture-model"))
            let fixtures: [(String, String, String, TokenUsage, TaskAPICostEstimate, TaskBackend)] = [
                ("cost-single", "API 参考费用 · 截图用量", "gpt-6.1-sol", screenshot, single, .codex),
                ("cost-mixed", "API 参考费用 · 多模型累计", mixedModels.last!,
                    TokenUsage(input: Int64(mixedModels.count) * 1_000_000, output: 0, cachedInput: 0,
                               total: Int64(mixedModels.count) * 1_000_000), mixed, .codex),
                ("cost-dsh", "API 参考费用 · DeepSeek 峰谷区间", "deepseek-flash", screenshot,
                    .dsh(usage: screenshot, model: "deepseek-flash"), .dsh),
                ("cost-partial", "API 参考费用 · 部分估算", "gpt-6.1-sol", screenshot, partial, .codex),
                ("cost-unavailable", "API 参考费用 · 未知模型", "unpriced-fixture-model", screenshot,
                    TaskAPICostEstimate(issues: [.unknownModel("unpriced-fixture-model")]), .codex)
            ]
            store.tasks = fixtures.map { id, title, model, tokens, cost, backend in
                TaskSnapshot(id: id, title: title, model: model, source: .desktop, parentID: nil,
                    startedAt: referenceDate.addingTimeInterval(-36), updatedAt: referenceDate, tokens: tokens,
                    activity: .running, backend: backend, apiCostSource: .recorded(cost))
            }
        case .tokenBreakdown:
            store.tasks = [
                TaskSnapshot(id: "token-parent", title: "任务明细 · 固定夹具", model: "example-coding-model",
                    source: .desktop, parentID: nil, startedAt: referenceDate.addingTimeInterval(-9_960),
                    updatedAt: referenceDate, tokens: TokenUsage(input: 435_519_979, output: 904_902,
                        cachedInput: 432_755_456, reasoningOutput: 507_192, total: 436_424_881), activity: .running,
                    contextUsage: ContextWindowUsage(used: 230_000, window: 1_000_000, recordedAt: referenceDate),
                    sessionStatistics: TaskSessionStatistics(toolMilliseconds: 2_387_000, meanTTFTMilliseconds: 1_300,
                                                             ttftSampleCount: 7)),
                TaskSnapshot(id: "token-child", title: "任务明细检查 · 子代理", model: "example-coding-model",
                    source: .subtask, parentID: "token-parent", startedAt: referenceDate.addingTimeInterval(-187),
                    updatedAt: referenceDate, tokens: TokenUsage(input: 1_493_699, output: 7_891,
                        cachedInput: 1_397_632, reasoningOutput: 546, total: 1_501_590), activity: .running,
                    agentPath: "/root/task_details_review", agentNickname: "FixtureAgent", agentRole: "reviewer",
                    progress: TaskProgress(kind: .message, text: "已核对任务用量、缓存占比与完整数值。正在检查独立展开、收起和窗口高度恢复，验证较长的任务进展可以完整读取。"),
                    contextUsage: ContextWindowUsage(used: 80_000, window: 475_000, recordedAt: referenceDate),
                    sessionStatistics: TaskSessionStatistics(toolMilliseconds: 31_000, meanTTFTMilliseconds: 2_700,
                                                             ttftSampleCount: 2)),
                TaskSnapshot(id: "token-deep", title: "长名称子代理 · 完整路径和极长数值换行验证",
                    model: "example-long-model-name-for-layout-validation", source: .subtask, parentID: "token-child",
                    startedAt: referenceDate.addingTimeInterval(-90), updatedAt: referenceDate,
                    tokens: TokenUsage(input: Int64.max / 2, output: Int64.max / 2, cachedInput: Int64.max / 3,
                        reasoningOutput: Int64.max / 4, total: Int64.max - 1), activity: .running,
                    agentPath: "/root/task_details_review/very_long_nested_path_for_truncation_checks",
                    agentNickname: "A very long subagent nickname for layout validation",
                    progress: TaskProgress(kind: .tool, text: L10n.text("Running command")),
                    contextUsage: ContextWindowUsage(used: Int64.max - 1, window: Int64.max / 2),
                    sessionStatistics: TaskSessionStatistics(toolMilliseconds: 0, historyUnreadable: true))
            ]
        case .tokenEdges:
            store.tasks = [
                TaskSnapshot(id: "token-zero", title: "Zero input and output", model: nil, source: .desktop,
                    parentID: nil, startedAt: referenceDate, updatedAt: referenceDate,
                    tokens: TokenUsage(input: 0, output: 0, cachedInput: 0, reasoningOutput: 0, total: 0), activity: .running,
                    contextUsage: ContextWindowUsage(used: 0, window: 475_000),
                    sessionStatistics: TaskSessionStatistics(toolMilliseconds: 0, meanTTFTMilliseconds: 0, ttftSampleCount: 1)),
                TaskSnapshot(id: "token-missing", title: "Unavailable usage", model: nil, source: .subtask,
                    parentID: "token-zero", startedAt: nil, updatedAt: referenceDate,
                    tokens: TokenUsage(), activity: .running),
                TaskSnapshot(id: "token-invalid", title: "Inconsistent source total and invalid subsets", model: "fixture",
                    source: .desktop, parentID: nil, startedAt: referenceDate, updatedAt: referenceDate,
                    tokens: TokenUsage(input: 100, output: 20, cachedInput: 101, reasoningOutput: 21, total: 121), activity: .running)
            ]
        case .taskFamily, .familyExpanded:
            store.tasks = [task(1), task(2, parentID: "demo-1"), task(3, parentID: "demo-1", activity: .unknown),
                           task(4, parentID: "demo-2")]
            store.tasks[1] = TaskSnapshot(id: "demo-2", title: "任务家族检查 · 子代理", model: "example-coding-model",
                source: .subtask, parentID: "demo-1", startedAt: referenceDate.addingTimeInterval(-210),
                updatedAt: referenceDate, tokens: TokenUsage(input: 240_400, output: 1_300, total: 241_700), activity: .running,
                agentPath: "/root/task_family_review", agentNickname: "FixtureReviewer", agentRole: "reviewer",
                progress: TaskProgress(kind: .message, text: "已核对父子任务分组、运行数量和多层缩进。正在检查祖先缺失与状态待确认的显示，确保长进展文本能正确截断并通过悬停查看。"))
            store.tasks[3].progress = TaskProgress(kind: .tool, text: L10n.text("Running command"))
        case .familyContext:
            store.taskAncestors = [TaskReference(id: "completed-parent", title: "已结束父任务的归属标题", parentID: nil)]
            store.tasks = [task(1, parentID: "completed-parent"), task(2, activity: .unknown),
                           task(3, parentID: "demo-2"), task(4, parentID: "missing-parent")]
        case .dshOnly, .dshIdle, .dshUnknown, .dshError, .noSources, .mixedError,
             .loading, .empty, .error, .noQuota, .quotaRingLow, .quotaRingHigh,
             .resetCredits, .resetCreditsExpired, .resetCreditsUnknown, .resetCreditsZero,
             .resetCreditsUnavailable, .resetCreditsOverflow, .resetCreditsOnly:
            break
        }
        if scenario == .taskProjects || scenario == .multiple {
            let projects = [
                TaskProject(id: "preview-veyra", name: "Veyra", roots: ["/Projects/Veyra"]),
                TaskProject(id: "preview-other", name: "Veyra", roots: ["/Projects/Other/Veyra"]),
                TaskProject(id: "preview-long", name: "跨项目协作与长名称布局验证 · Long project name for overflow checks",
                            roots: ["/Projects/Long name"])
            ]
            for index in store.tasks.indices {
                let project = store.tasks[index].backend == .dsh ? projects[0] : projects[min(index / 5, 2)]
                store.tasks[index].projectAssignment = index == 14 ? .unassigned : .project(project)
            }
        }
    }

    private static func resetCredit(after seconds: TimeInterval) -> JSONValue {
        .object(["status": .string("available"),
                 "expiresAt": .number(referenceDate.addingTimeInterval(seconds).timeIntervalSince1970)])
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
                     model: "example-coding-model", source: parentID == nil ? .desktop : .subtask, parentID: parentID,
                     startedAt: referenceDate.addingTimeInterval(-752), updatedAt: referenceDate,
                     tokens: TokenUsage(input: 877_208, output: 6_892, cachedInput: 698_400, reasoningOutput: 2_891, total: 884_100),
                     activity: activity)
    }

    private static func dshTask(_ number: Int, activity: TaskActivity = .running) -> TaskSnapshot {
        TaskSnapshot(id: "dsh:demo-\(number)", title: "按设计实施 dsh 数据源并核对缓存命中率 · \(number)",
                     model: "kimi-k3", source: .desktop, parentID: nil,
                     startedAt: referenceDate.addingTimeInterval(-418), updatedAt: referenceDate,
                     tokens: TokenUsage(input: 963_704, output: 17_773, cachedInput: 763_904, total: 981_477),
                     activity: activity, backend: .dsh)
    }

    private static func panel(store: MonitorStore, scenario: Scenario, screenHeight: CGFloat = 800, increasedContrast: Bool = false,
                              onSizingChange: @escaping (PanelSizing) -> Void) -> some View {
        MonitorPanel(store: store, updates: .preview(scenario == .updateAvailable ? .available : .idle),
                     screenOverride: PanelScreenMetrics(visibleHeight: screenHeight),
                     initiallyExpandedTaskIDs: expandedTaskIDs(for: scenario),
                     initiallyShowUnknown: scenario == .unknown || scenario == .taskProjects || scenario == .dshUnknown, onSizingChange: onSizingChange)
            .environment(\.monitorOpaquePreview, true)
            .environment(\.monitorPreviewContrast, increasedContrast ? .increased : .standard)
            .environment(\.monitorReferenceDate, referenceDate)
    }

    static func render(to directory: URL) {
        Task { @MainActor in
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                if CommandLine.arguments.contains("--exercise-settings-only") {
                    try await SettingsInteractionChecks.run(to: directory)
                    NSApp.terminate(nil)
                    return
                }
                let store = MonitorStore()
                var results: [[String: Any]] = []
                let dshOnly = CommandLine.arguments.contains("--preview-dsh-only")
                let scenarios: [Scenario] = CommandLine.arguments.contains("--preview-settings-only") ? []
                    : (dshOnly ? [.dshOnly, .dshIdle, .dshUnknown, .dshError, .noSources, .mixedError] : Scenario.allCases)
                if !scenarios.isEmpty { try renderStatusItems(to: directory) }
                if !scenarios.isEmpty && !dshOnly {
                    try await TaskDetailInteractionChecks.run(to: directory)
                    try await TaskInfoInteractionChecks.run(to: directory)
                }
                for scenario in scenarios {
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
                        // Include the reset-credit card and quota refresh controls;
                        // production height always comes from the actual content.
                        let heightBudget: CGFloat = scenario == .single ? 560 : 776
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
                // Fixed settings fixtures never expose the user's configured paths.
                let settingsCases = dshOnly ? [(SettingsScenario.missing, UpdateStore.PreviewState.idle)]
                    : UpdateStore.PreviewState.allCases.map { (SettingsScenario.automatic, $0) }
                        + SettingsScenario.allCases.filter { $0 != .automatic }.map { ($0, UpdateStore.PreviewState.idle) }
                for (settingsScenario, updateState) in settingsCases {
                    let settingsStore = settingsStore(settingsScenario)
                    for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua),
                                               ("light-increased", .accessibilityHighContrastAqua),
                                               ("dark-increased", .accessibilityHighContrastDarkAqua)] {
                        let hosting = NSHostingView(rootView: MonitorSettings(store: settingsStore, updates: .preview(updateState))
                            .frame(width: SettingsLayout.width, height: 720)
                            .environment(\.monitorReferenceDate, referenceDate)
                            .background(Color(nsColor: .windowBackgroundColor)))
                        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: SettingsLayout.width, height: 1),
                                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
                        window.title = L10n.text("Veyra Settings")
                        window.appearance = NSAppearance(named: appearance)
                        window.contentView = hosting
                        window.orderFront(nil)
                        retainedWindow = window
                        for iteration in 0..<5 {
                            try await Task.sleep(for: .milliseconds(80))
                            hosting.layoutSubtreeIfNeeded()
                            window.setContentSize(hosting.fittingSize)
                            if settingsScenario == .invalidDraft, iteration == 1,
                               let field = settingsFields(in: hosting).first {
                                field.stringValue = "relative/invalid-path"
                                field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
                                field.delegate?.controlTextDidEndEditing?(Notification(name: NSControl.textDidEndEditingNotification, object: field))
                            }
                        }
                        guard abs(hosting.bounds.width - SettingsLayout.width) < 1,
                              hosting.bounds.height > 100 else {
                            throw PreviewError.invalidLayout("settings-\(name)")
                        }
                        let filename = settingsScenario != .automatic ? "settings-\(settingsScenario.rawValue)-\(name)"
                            : (updateState == .idle ? "settings-\(name)" : "settings-\(updateState.rawValue)-\(name)")
                        try saveBitmap(hosting, to: directory.appendingPathComponent(filename + ".png"))
                        results.append(["name": filename, "width": hosting.bounds.width,
                                        "height": hosting.bounds.height])
                        window.orderOut(nil)
                        retainedWindow = nil
                    }
                }
                if CommandLine.arguments.contains("--exercise-settings") {
                    try await SettingsInteractionChecks.run(to: directory)
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

    private static func renderStatusItems(to directory: URL) throws {
        let samples: [([Double?], String, Bool)] = [
            ([100], "0", true), ([30], "1", true), ([29.9], "2", true), ([10], "12", true),
            ([9.9], "—", true), ([0.4], "2", true), ([0], "123", true), ([], "—", true),
            ([9.9, 29.9], "2", true), ([29.9, 80], "2", true), ([80, 9.9], "2", true),
            ([0, nil], "2", true), ([], "1234", false)
        ]
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua),
                                  ("light-contrast", .accessibilityHighContrastAqua),
                                  ("dark-contrast", .accessibilityHighContrastDarkAqua)] {
            // Rows: current values, stale values after failure, and native highlight.
            let strip = NSView(frame: NSRect(x: 0, y: 0, width: 8 + samples.count * 116, height: 108))
            strip.wantsLayer = true
            strip.layer?.backgroundColor = (name.hasPrefix("light") ? NSColor.white : .black).cgColor
            strip.appearance = NSAppearance(named: appearance)
            var currentImages: [NSImage] = []
            for row in 0..<3 {
                for (index, sample) in samples.enumerated() {
                    var quotaState = QuotaDisplayState()
                    let windows = sample.0.enumerated().map { index, value in
                        QuotaWindow(id: "codex:\(index)", bucketID: "codex", bucketName: "Codex", isPrimary: index == 0,
                                    usedPercent: value.map { 100 - $0 },
                                    durationMinutes: sample.0.count == 2 && index == 0 ? 300 : 10_080, resetsAt: nil)
                    }
                    quotaState.apply(QuotaRefresh(snapshot: QuotaSnapshot(
                        windows: windows,
                        fetchedAt: referenceDate, accountID: nil)))
                    if row == 1 { quotaState.apply(QuotaRefresh(error: .rpcFailed)) }
                    let button = NSButton(frame: NSRect(x: 8 + index * 116, y: 7 + row * 36, width: 108, height: 22))
                    button.isBordered = false
                    button.imagePosition = .imageOnly
                    button.title = ""
                    let image = MenuBarController.statusImage(quotaWindows: quotaState.snapshot?.menuWindows ?? [],
                        showsQuota: sample.2, taskCount: sample.1,
                        appearance: strip.effectiveAppearance, highlighted: row == 2,
                        increasedContrast: name.hasSuffix("-contrast"))
                    if row == 0 { currentImages.append(image) }
                    if windows.count == 2 {
                        let single = MenuBarController.statusImage(quotaWindows: Array(windows.prefix(1)),
                            showsQuota: true, taskCount: sample.1)
                        guard image.size.width - single.size.width == 28 else {
                            throw PreviewError.invalidLayout("status-item-dual-width-\(name)-\(index)")
                        }
                    }
                    if row == 1 {
                        guard image.isTemplate == currentImages[index].isTemplate,
                              image.tiffRepresentation == currentImages[index].tiffRepresentation else {
                            throw PreviewError.invalidLayout("status-item-color-after-quota-failure-\(name)-\(index)")
                        }
                    }
                    button.image = image
                    button.contentTintColor = name.hasPrefix("light") ? .black : .white
                    strip.addSubview(button)
                }
            }
            try saveBitmap(strip, to: directory.appendingPathComponent("status-items-\(name).png"))
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
