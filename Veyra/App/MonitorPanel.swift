import SwiftUI

private let monitorAccent = Color(nsColor: .systemGreen)

struct MonitorPanel: View {
    @Bindable var store: MonitorStore
    var updates: UpdateStore?
    var screenOverride: PanelScreenMetrics?
    var onSizingChange: ((PanelSizing) -> Void)?
    var openSettings: (() -> Void)?
    @State private var showUnknown = false
    @State private var expandedTaskIDs: Set<String> = []
    @State private var infoPresenter: TaskInfoPresenter
    @State private var contentHeight: CGFloat = 1
    @State private var headerHeight: CGFloat = 0
    @State private var footerHeight: CGFloat = 0
    @State private var screen = PanelScreenMetrics(visibleHeight: 800)
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.monitorOpaquePreview) private var opaquePreview

    init(store: MonitorStore, updates: UpdateStore? = nil, screenOverride: PanelScreenMetrics? = nil,
         initiallyExpandedTaskIDs: Set<String> = [], initiallyShowUnknown: Bool = false,
         onSizingChange: ((PanelSizing) -> Void)? = nil, openSettings: (() -> Void)? = nil,
         infoPresenter: TaskInfoPresenter? = nil) {
        self.store = store
        self.updates = updates
        self.screenOverride = screenOverride
        self.onSizingChange = onSizingChange
        self.openSettings = openSettings
        _expandedTaskIDs = State(initialValue: initiallyExpandedTaskIDs)
        _infoPresenter = State(initialValue: infoPresenter ?? TaskInfoPresenter())
        _showUnknown = State(initialValue: initiallyShowUnknown)
    }

    var body: some View {
        VStack(spacing: 0) {
            MonitorPanelHeader(openSettings: { openSettings?() })
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self, of: { ceil($0.size.height) }) { headerHeight = $0 }
                .accessibilityIdentifier("monitor.header")
            ScrollView {
                // Eager layout is intentional: measure the one real content tree,
                // including offscreen rows and disclosures, not a lazy estimate.
                VStack(alignment: .leading, spacing: 16) {
                    if store.showsQuota { quotaSection }
                    tasksSection
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self, of: { ceil($0.size.height) }) { contentHeight = $0 }
            }
            .frame(height: sizing.viewportHeight)
            .scrollDisabled(!sizing.isScrollable)
            .scrollBounceBehavior(.basedOnSize)
            .scrollClipDisabled(false)
            .clipShape(Rectangle())
            .accessibilityIdentifier("monitor.content")
            footer
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self, of: { ceil($0.size.height) }) { footerHeight = $0 }
                .accessibilityIdentifier("monitor.footer")
        }
        .frame(width: PanelSizing.width)
        .fixedSize(horizontal: false, vertical: true)
        .background {
            if reduceTransparency || opaquePreview { Color(nsColor: .windowBackgroundColor) }
        }
        .background {
            PanelWindowReader(onChange: { screen = $0 }, onVisibilityChange: { visible in
                store.setPanelVisible(visible)
                if visible, !store.isPreview {
                    Task { await updates?.checkAutomatically() }
                }
            })
                .allowsHitTesting(false)
        }
        .environment(\.monitorPanelActive, store.panelVisible || store.isPreview)
        .environment(\.taskInfoPresenter, infoPresenter)
        .foregroundStyle(.primary)
        .onChange(of: sizing, initial: true) { _, value in onSizingChange?(value) }
        .onChange(of: store.tasks.map(\.id)) { _, ids in
            expandedTaskIDs.formIntersection(ids)
        }
        .onDisappear { infoPresenter.dismiss(restoringFocus: false) }
    }

    private var sizing: PanelSizing {
        PanelSizing(contentHeight: contentHeight, headerHeight: headerHeight, footerHeight: footerHeight,
                    screen: screenOverride ?? screen)
    }

    private func expandedBinding(for id: String) -> Binding<Bool> {
        Binding(get: { expandedTaskIDs.contains(id) }, set: { expanded in
            if expanded { expandedTaskIDs.insert(id) } else { expandedTaskIDs.remove(id) }
        })
    }

    private var quotaSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                sectionTitle("Codex quota")
                    .help(store.runningTasks.isEmpty ? L10n.text("Auto sync every hour while idle") : L10n.text("Auto sync every minute while tasks run"))
                if let plan = store.quota.account?.planDisplayName {
                    Text(plan).font(.system(size: 9, weight: .semibold, design: .rounded))
                        .tracking(0.5).lineLimit(1).help(plan)
                        .padding(.horizontal, 7).padding(.vertical, 4)
                        .background(.primary.opacity(0.08), in: Capsule()).foregroundStyle(.secondary)
                }
                if store.quotaBusy {
                    ProgressView().controlSize(.small).scaleEffect(0.8)
                        .frame(width: 14, height: 14)
                        .accessibilityLabel("Syncing quota online")
                        .accessibilityIdentifier("monitor.quotaProgress")
                }
                Spacer()
                MonitorTimeline(interval: 1, enabled: store.nextCalibrationAt != nil, deadline: store.nextCalibrationAt) { now in
                    HStack(spacing: 7) {
                        if let next = store.nextCalibrationAt, next > now {
                            Text(L10n.text("Sync after \(next.formatted(date: .omitted, time: .standard))"))
                                .font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
                        }
                        MonitorActionButton(systemName: "arrow.clockwise", label: L10n.text("Sync quota"),
                                            help: L10n.text("Sync quota online"), identifier: "monitor.calibrate") {
                            Task { await store.calibrateQuota() }
                        }
                        .disabled(store.quotaBusy || store.nextCalibrationAt.map { now < $0 } == true)
                    }
                }
            }
            if let snapshot = store.quota.snapshot, !snapshot.windows.isEmpty {
                let bucketIDs = snapshot.windows.reduce(into: [String]()) { ids, window in
                    if !ids.contains(window.bucketID) { ids.append(window.bucketID) }
                }
                ForEach(bucketIDs, id: \.self) { id in
                    let windows = snapshot.windows.filter { $0.bucketID == id }
                    VStack(alignment: .leading, spacing: 10) {
                        if id != "codex" {
                            Text(windows.first?.bucketName ?? id)
                                .font(.system(size: 12, weight: .semibold)).foregroundStyle(.primary)
                        }
                        VStack(spacing: 12) {
                            ForEach(windows) { window in
                                if window.id != windows.first?.id {
                                    Divider().accessibilityHidden(true)
                                }
                                QuotaWindowView(window: window)
                            }
                        }
                    }
                    .padding(14).monitorCard()
                }
            } else if store.quotaBusy {
                HStack(spacing: 9) {
                    ProgressView().controlSize(.small)
                    Text("Syncing quota online…").font(.system(size: 12)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, minHeight: 56).monitorCard()
            } else {
                Text("No online quota data").font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 44).monitorCard()
            }
            ResetCreditsCard(snapshot: store.quota.resetCredits, isLoading: store.quotaBusy)
            if let error = store.quota.error { notice(error) }
        }
    }

    private var tasksSection: some View {
        let groups = TaskGroup.make(tasks: store.tasks, ancestors: store.taskAncestors)
        let runningGroups = groups.filter(\.isRunning)
        let unknownGroups = groups.filter { !$0.isRunning }
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                sectionTitle("Running tasks")
                    .help(L10n.text("Checks every \(store.pollingSeconds) seconds"))
                    .accessibilityValue(L10n.text("Checks every \(store.pollingSeconds) seconds"))
                Text("\(store.runningTasks.count)")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.primary).padding(.horizontal, 7).padding(.vertical, 3)
                    .background(.primary.opacity(0.08), in: Capsule())
                if store.tasksBusy {
                    ProgressView().controlSize(.small).scaleEffect(0.8)
                        .frame(width: 14, height: 14)
                        .accessibilityLabel("Refreshing running tasks")
                        .accessibilityIdentifier("monitor.tasksProgress")
                }
                Spacer()
                MonitorTaskSourceStatus(
                    hasTaskError: store.hasSourceWarning,
                    detecting: store.noSourcesFound || (!store.hasTaskSnapshot && !store.sourceDetectionFinished)
                )
            }
            .zIndex(1)
            if store.runningTasks.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: !store.sourceDetectionFinished ? "ellipsis" : "checkmark.circle")
                        .font(.system(size: 20, weight: .light)).foregroundStyle(.tertiary)
                    Text(store.noSourcesFound
                         ? L10n.text("No local Codex or dsh data found. Choose a data directory in Settings.")
                         : (!store.sourceDetectionFinished && !store.hasSourceWarning ? L10n.text("Reading local tasks…") : L10n.text("No confirmed running tasks")))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity).padding(.vertical, 16).monitorCard()
            } else {
                projectCards(groups: runningGroups, unknown: false)
            }
            if !unknownGroups.isEmpty {
                DisclosureGroup(isExpanded: $showUnknown) {
                    VStack(spacing: 10) {
                        Text("These sessions have not ended, but no running process could be confirmed. They are excluded from the running count.")
                            .font(.system(size: 11)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                        projectCards(groups: unknownGroups, unknown: true)
                    }.padding(.top, 10)
                } label: {
                    Label(L10n.text("Unconfirmed status · \(unknownGroups.reduce(0) { $0 + $1.unknownCount })"), systemImage: "questionmark.circle")
                        .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            if store.codexHasNoTaskData {
                Text("Codex has no task data yet.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if let warning = store.codexServiceWarning { notice(warning) }
            if let error = store.taskError { notice(error) }
            if let warning = store.taskWarning { notice(warning.message) }
            if let warning = store.dshWarning { notice(warning) }
        }
    }

    private func projectCards(groups: [TaskGroup], unknown: Bool) -> some View {
        let projects = TaskProjectGroup.make(groups: groups)
        return VStack(alignment: .leading, spacing: 20) {
            ForEach(projects) { project in
                VStack(alignment: .leading, spacing: 8) {
                    TaskProjectHeader(project: project, unknown: unknown)
                    VStack(spacing: 12) {
                        ForEach(project.groups) { group in TaskGroupCard(group: group, expansion: expandedBinding) }
                    }
                }
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            if let release = updates?.availableRelease {
                HStack(spacing: 8) {
                    Text(L10n.text("New version available: \(release.version)"))
                        .font(.system(size: 11, weight: .medium)).monospacedDigit()
                    Spacer(minLength: 4)
                    UpdateDownloadLink(release: release).font(.system(size: 11))
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .accessibilityIdentifier("updates.banner")
            }
        }
    }

    private func sectionTitle(_ title: LocalizedStringKey) -> some View {
        Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.primary)
    }
    private func notice(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.circle")
            .font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
    }
}

private struct TaskProjectHeader: View {
    let project: TaskProjectGroup
    let unknown: Bool

    var body: some View {
        let summary = project.counts(for: unknown ? .unknown : .running).summary
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: project.title)
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(.primary)
                .lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 2) {
                if unknown { Text("Unconfirmed") }
                Text(verbatim: summary).monospacedDigit()
            }
            .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize()
        }
        .help(([project.title] + (project.project?.roots ?? [])).joined(separator: "\n"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(unknown
            ? L10n.text("\(project.title) · \(project.unknownCount) unconfirmed tasks")
            : L10n.text("\(project.title) · \(project.runningCount) running tasks"))
        .accessibilityValue(summary)
        .accessibilityIdentifier("monitor.project.\(project.id).\(unknown ? "unknown" : "running")")
    }
}

private struct MonitorPanelHeader: View {
    let openSettings: () -> Void

    var body: some View {
        HStack(spacing: 11) {
            VeyraIcon(size: 28)
            VeyraWordmark(width: 56)
            Spacer()
            MonitorPanelActions(openSettings: openSettings)
        }
        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)
    }
}

private struct MonitorTaskSourceStatus: View {
    let hasTaskError: Bool
    let detecting: Bool

    var body: some View {
        HStack(spacing: 5) {
            Text("This Mac").foregroundStyle(.secondary)
            Circle().fill(hasTaskError ? .orange : (detecting ? .secondary : monitorAccent))
                .frame(width: 5, height: 5)
                .accessibilityHidden(true)
        }
        .font(.system(size: 11)).fixedSize()
        .help("Only tasks on this Mac are shown. Cloud tasks and tasks on other devices are not included.")
        .accessibilityElement(children: .combine)
        .accessibilityHint("Only tasks on this Mac are shown. Cloud tasks and tasks on other devices are not included.")
        .accessibilityIdentifier("monitor.taskSource")
    }
}

private struct MonitorPanelActions: View {
    let openSettings: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            MonitorActionButton(systemName: "gearshape", label: L10n.text("Settings"),
                                help: L10n.text("Settings"), identifier: "monitor.settings") {
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            }
            MonitorActionButton(systemName: "power", label: L10n.text("Quit Veyra"),
                                help: L10n.text("Quit Veyra"), identifier: "monitor.quit") {
                NSApplication.shared.terminate(nil)
            }
        }
        .foregroundStyle(.secondary)
    }
}

private struct QuotaWindowView: View {
    let window: QuotaWindow
    @Environment(\.locale) private var locale
    @Environment(\.monitorReferenceDate) private var referenceDate

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 0) {
                Text(window.durationTitle)
                    .font(.system(size: 13, weight: .medium)).monospacedDigit()
                Spacer(minLength: 8)
                resetLabel
            }
            .frame(minHeight: 56, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            QuotaRingView(remainingPercent: window.remainingPercent)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("monitor.quota.\(window.id)")
    }

    private var resetLabel: some View {
        Group {
            if let reset = window.resetsAt {
                MonitorTimeline(interval: 30) { now in
                    Text(reset > (referenceDate ?? now) ? L10n.text("Resets \(reset.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale)))") : L10n.text("Reset due · Awaiting update"))
                }
            } else {
                Text("Reset time unavailable")
            }
        }
        .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
    }
}

private struct QuotaRingView: View {
    let remainingPercent: Double?

    private var tint: Color {
        guard let remaining = remainingPercent else { return .secondary }
        return remaining < 10 ? .red : remaining < 30 ? .orange : monitorAccent
    }

    var body: some View {
        ZStack {
            Circle().strokeBorder(tint.opacity(0.12), lineWidth: 5)
            if let remaining = remainingPercent, remaining > 0 {
                Circle().inset(by: 2.5)
                    .trim(from: 0, to: remaining / 100)
                    .stroke(tint, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            Text(DisplayFormat.percent(remainingPercent))
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .monospacedDigit().foregroundStyle(tint)
                .fixedSize()
        }
        .frame(width: 56, height: 56)
        .accessibilityElement(children: .ignore)
        // Keep the percentage in the label so the combined quota row retains it.
        .accessibilityLabel(remainingPercent == nil ? L10n.text("Remaining quota unavailable") : L10n.text("Remaining quota \(DisplayFormat.percent(remainingPercent))"))
    }
}

private struct TaskGroupCard: View {
    let group: TaskGroup
    let expansion: (String) -> Binding<Bool>

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(group.rows) { row in
                let indent = CGFloat(min(row.depth, 3)) * 10
                if row.id != group.rows.first?.id {
                    Divider().padding(.leading, 14 + indent).padding(.trailing, 14)
                }
                Group {
                    if let task = row.task {
                        TaskRow(task: task, isSubagent: row.isSubagent,
                                expanded: expansion(task.id))
                    } else {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(row.reference.title).font(.system(size: 13, weight: .semibold))
                                .lineLimit(2).fixedSize(horizontal: false, vertical: true).help(row.reference.title)
                            Label("Parent task", systemImage: "arrow.triangle.branch")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(14).padding(.leading, indent)
                .accessibilityElement(children: .contain)
                .accessibilityLabel(row.parentTitle.map { L10n.text("\(row.reference.title), from \($0)") } ?? row.reference.title)
                .accessibilityIdentifier("monitor.task.\(row.id)")
            }
        }
        .monitorCard()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("monitor.task-group.\(group.id)")
    }
}

private struct TaskRow: View {
    let task: TaskSnapshot
    let isSubagent: Bool
    @Binding var expanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TaskIdentityHeader(title: task.title, path: task.agentPath,
                               source: isSubagent ? TaskText.subagentBadge(nickname: task.agentNickname) : task.sourceLabel,
                               sourceIcon: isSubagent ? "arrow.triangle.branch" : task.source.iconName,
                               sourceDetail: isSubagent ? TaskText.subagentBadge(nickname: task.agentNickname) : task.sourceDetail,
                               model: task.model,
                               modelDetail: TaskText.modelDetail(model: task.model, provider: task.modelProvider,
                                                                 effort: task.reasoningEffort),
                               activity: task.activity, startedAt: task.startedAt)
            if let progress = task.progress { TaskProgressSection(progress: progress) }
            if expanded, let role = TaskText.nonempty(task.agentRole) {
                Text(L10n.text("\(L10n.text("Role")): \(role)"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            if task.backend == .codex {
                TaskContextUsageView(taskID: task.id, usage: task.contextUsage)
                    .padding(.top, 4)
            }
            TaskTokenSummary(taskID: task.id, title: task.title, tokens: task.tokens,
                             isSubagent: isSubagent, expanded: $expanded)
                .padding(.top, 4)
            if expanded {
                TaskTokenDetails(task: task)
                    .padding(.top, 4)
            }
        }
    }
}

private struct TaskIdentityHeader: View {
    let title: String
    let path: String?
    let source: String
    let sourceIcon: String
    let sourceDetail: String
    let model: String?
    let modelDetail: String?
    let activity: TaskActivity
    let startedAt: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true).help(title)
                    if let path = TaskText.nonempty(path) {
                        Text(path).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle).help(path)
                            .accessibilityLabel(L10n.text("Task path: \(path)"))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Circle().fill(activity == .running ? monitorAccent : .orange)
                    .frame(width: 6, height: 6).padding(.top, 5)
                    .accessibilityLabel(activity == .running ? L10n.text("Running") : L10n.text("Unconfirmed status"))
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    badges.fixedSize()
                    Spacer(minLength: 0)
                    TaskElapsedTime(activity: activity, startedAt: startedAt).fixedSize()
                }
                VStack(alignment: .leading, spacing: 5) {
                    badges
                    TaskElapsedTime(activity: activity, startedAt: startedAt)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
    }

    private var badges: some View {
        TaskIdentityBadges(source: source, sourceIcon: sourceIcon, sourceDetail: sourceDetail,
                           model: model, modelDetail: modelDetail)
    }
}

private struct TaskIdentityBadges: View {
    let source: String
    let sourceIcon: String
    let sourceDetail: String
    let model: String?
    let modelDetail: String?

    var body: some View {
        HStack(spacing: 6) {
            TaskBadge(source, systemImage: sourceIcon)
                .lineLimit(1).truncationMode(.tail).help(sourceDetail)
                .accessibilityLabel(sourceDetail)
            TaskBadge(model ?? L10n.text("Unknown model"), systemImage: "sparkles")
                .lineLimit(1).truncationMode(.tail).help(modelDetail ?? model ?? L10n.text("Unknown model"))
                .accessibilityLabel(modelDetail ?? model ?? L10n.text("Unknown model"))
        }
    }
}

private struct TaskElapsedTime: View {
    let activity: TaskActivity
    let startedAt: Date?
    @Environment(\.monitorReferenceDate) private var referenceDate

    var body: some View {
        Group {
            if activity == .running {
                MonitorTimeline(interval: 1) { now in
                    Label(DisplayFormat.duration(since: startedAt, now: referenceDate ?? now), systemImage: "clock")
                }
            } else { Label("Unknown status", systemImage: "clock") }
        }
        .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
    }
}

private struct TaskProgressSection: View {
    let progress: TaskProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(progress.label).font(.system(size: 11, weight: .medium))
            Text(progress.text).font(.system(size: 11)).foregroundStyle(.secondary)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true).help(progress.text)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.text("\(progress.label): \(progress.text)"))
    }
}

private struct TaskTokenSummary: View {
    let taskID: String
    let title: String
    let tokens: TokenUsage
    let isSubagent: Bool
    @Binding var expanded: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "cylinder")
            Text(isSubagent ? L10n.text("Subtask tokens") : L10n.text("Task tokens"))
                .font(.system(size: 11, weight: .medium))
            Spacer(minLength: 4)
            Text(DisplayFormat.tokens(tokens.total.flatMap { $0 >= 0 ? $0 : nil }))
                .font(.system(size: 14, weight: .medium)).monospacedDigit().fixedSize()
            Image(systemName: expanded ? "chevron.up" : "chevron.down")
                .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 22)
        .accessibilityHidden(true)
        .overlay {
            TaskTokenDisclosure(identifier: "monitor.tokens.\(taskID)",
                label: L10n.text("\(title), total token breakdown"),
                value: L10n.text("\(TaskTokenText.totalHelp(tokens)), \(expanded ? L10n.text("Expanded") : L10n.text("Collapsed"))"),
                help: TaskTokenText.totalHelp(tokens)) { expanded.toggle() }
        }
    }
}

/// Keep the SwiftUI label with a native keyboard-focusable disclosure control.
private struct TaskTokenDisclosure: NSViewRepresentable {
    let identifier: String
    let label: String
    let value: String
    let help: String
    var action: @MainActor () -> Void

    @MainActor final class Coordinator: NSObject {
        var action: @MainActor () -> Void
        init(action: @escaping @MainActor () -> Void) { self.action = action }
        @objc func invoke() { action() }
    }

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }
    func makeNSView(context: Context) -> TaskTokenNativeButton {
        let button = TaskTokenNativeButton(title: "", target: context.coordinator, action: #selector(Coordinator.invoke))
        button.isBordered = false
        button.isTransparent = true
        button.focusRingType = .exterior
        return button
    }
    func updateNSView(_ button: TaskTokenNativeButton, context: Context) {
        context.coordinator.action = action
        button.setAccessibilityIdentifier(identifier)
        button.setAccessibilityLabel(label)
        button.spokenValue = value
        button.toolTip = help
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TaskTokenNativeButton, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? PanelSizing.width - 60, height: proposal.height ?? 22)
    }
}

private final class TaskTokenNativeButton: MonitorNativeButton {
    var spokenValue = ""
    override var acceptsFirstResponder: Bool { true }
    override func accessibilityValue() -> Any? { spokenValue }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49 || event.keyCode == 36 {
            if !event.isARepeat { performClick(nil) }
        } else { super.keyDown(with: event) }
    }
}

private struct TaskTokenDetails: View {
    let task: TaskSnapshot
    private var tokens: TokenUsage { task.tokens }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TaskCacheShare(percent: tokens.cachedInputPercent)
            VStack(spacing: 6) {
                TaskTokenDetailLine(label: "Cache read", value: tokens.cachedInput)
                TaskTokenDetailLine(label: "Uncached input", value: tokens.uncachedInput)
                TaskOutputDetailLine(tokens: tokens)
            }
            TaskAPICostView(task: task)
            if task.backend == .codex {
                Divider().padding(.vertical, 2)
                TaskSessionStatisticsView(taskID: task.id, source: task.apiCostSource,
                    updatedAt: task.rolloutModifiedAt ?? task.updatedAt, tokens: task.tokens, fixture: task.sessionStatistics)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("monitor.token-details.\(task.id)")
    }
}

private struct TaskCacheShare: View {
    let percent: Double?
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.monitorPreviewContrast) private var previewContrast

    private var value: String {
        percent.map { $0.formatted(.number.precision(.fractionLength(1))) + "%" } ?? "—"
    }

    var body: some View {
        VStack(spacing: 5) {
            HStack {
                Text("Input cache share").foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text(value).monospacedDigit()
            }
            .font(.system(size: 11))
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.primary.opacity(0.08))
                    if let percent, percent > 0 {
                        Capsule().fill(Color(nsColor: .systemBlue))
                            .frame(width: geometry.size.width * min(100, max(0, percent)) / 100)
                    }
                }
                .overlay {
                    if (previewContrast ?? contrast) == .increased {
                        Capsule().strokeBorder(.secondary, lineWidth: 1)
                    }
                }
            }
            .frame(height: 4)
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.text("Input cache share"))
        .accessibilityValue(value)
    }
}

private struct TaskTokenDetailLine: View {
    let label: LocalizedStringKey
    let value: Int64?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(TaskTokenText.count(value)).monospacedDigit().fixedSize()
        }
        .font(.system(size: 11))
        .accessibilityElement(children: .combine)
    }
}

private struct TaskOutputDetailLine: View {
    let tokens: TokenUsage

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("Output (reasoning)").foregroundStyle(.secondary)
            Spacer(minLength: 0)
            TaskOutputNumbers(output: TaskTokenText.count(tokens.output),
                              reasoning: L10n.text("(\(TaskTokenText.count(tokens.includedReasoningOutput)))"))
        }
        .font(.system(size: 11))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(TaskTokenText.outputAccessibility(tokens))
    }
}

private struct TaskOutputNumbers: View {
    let output: String
    let reasoning: String

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 3) {
                Text(output).monospacedDigit()
                Text(reasoning).foregroundStyle(.secondary).monospacedDigit()
            }.fixedSize()
            VStack(alignment: .trailing, spacing: 2) {
                Text(output).monospacedDigit().fixedSize()
                Text(reasoning).foregroundStyle(.secondary).monospacedDigit().fixedSize()
            }
        }
    }
}

private struct TaskBadge: View {
    let text: String
    let systemImage: String

    init(_ text: String, systemImage: String) {
        self.text = text
        self.systemImage = systemImage
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
            Text(text)
        }
        .font(.system(size: 10, weight: .semibold, design: .rounded))
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(.primary.opacity(0.08), in: Capsule())
        .foregroundStyle(.secondary)
    }
}

private extension TaskSource {
    var iconName: String {
        switch self {
        case .cli: "terminal"
        case .desktop: "desktopcomputer"
        case .subtask: "arrow.triangle.branch"
        }
    }
}

private extension View {
    func monitorCard() -> some View {
        modifier(ControlCenterTile())
    }
}

private struct ResetCreditsCard: View {
    let snapshot: ResetCreditsSnapshot?
    let isLoading: Bool
    @Environment(\.locale) private var locale

    var body: some View {
        MonitorTimeline(interval: 1, enabled: snapshot?.credits.contains { $0.expiresAt != nil } == true) { now in
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Available resets").font(.system(size: 12, weight: .semibold))
                    Spacer(minLength: 8)
                    Text(snapshot?.totalLabel(at: now) ?? "—")
                        .font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit()
                        .accessibilityIdentifier("monitor.resetCredits.total")
                }
                .accessibilityElement(children: .combine)
                if let snapshot {
                    ForEach(snapshot.expiryGroups) { group in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(L10n.resetCount(Int64(group.count))).monospacedDigit().fixedSize()
                            Spacer(minLength: 0)
                            expiryLabel(group, at: now)
                                .monospacedDigit()
                                .multilineTextAlignment(.trailing)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .accessibilityElement(children: .combine)
                    }
                    if snapshot.availableCount == nil {
                        detail(L10n.text("Unavailable"))
                    } else if snapshot.hasIncompleteDetails {
                        detail(L10n.text("Some expiry details are unavailable"))
                    }
                } else {
                    detail(isLoading ? L10n.text("Syncing online…") : L10n.text("Sync quota to view"))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14).monitorCard()
            .accessibilityIdentifier("monitor.resetCredits")
        }
    }

    @ViewBuilder
    private func expiryLabel(_ group: ResetCreditsSnapshot.ExpiryGroup, at now: Date) -> some View {
        if let expiry = group.expiresAt {
            Text(group.isExpired(at: now) ? L10n.text("Expired · Sync needed") : L10n.text("Expires \(expiry.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale)))"))
                .help(L10n.text("Expires: \(expiry.formatted(Date.FormatStyle(date: .abbreviated, time: .standard).locale(locale)))"))
        } else {
            Text("Unknown expiry")
        }
    }

    private func detail(_ text: String) -> some View {
        Text(text).font(.system(size: 10)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct MonitorPanelActiveKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var monitorPanelActive: Bool {
        get { self[MonitorPanelActiveKey.self] }
        set { self[MonitorPanelActiveKey.self] = newValue }
    }
}

private struct MonitorTimeline<Content: View>: View {
    let interval: TimeInterval
    var enabled = true
    var deadline: Date?
    @ViewBuilder var content: (Date) -> Content
    @Environment(\.monitorPanelActive) private var active
    @Environment(\.monitorReferenceDate) private var referenceDate
    var body: some View {
        if let referenceDate { content(referenceDate) }
        else if active && enabled {
            if let deadline { TimelineView(.explicit([deadline])) { content($0.date) } }
            else { TimelineView(.periodic(from: .now, by: interval)) { content($0.date) } }
        } else { content(.now) }
    }
}
