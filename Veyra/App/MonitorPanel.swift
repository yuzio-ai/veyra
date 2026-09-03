import SwiftUI

private let monitorAccent = Color(nsColor: .systemGreen)

struct MonitorPanel: View {
    @Bindable var store: MonitorStore
    var screenOverride: PanelScreenMetrics?
    var onSizingChange: ((PanelSizing) -> Void)?
    @State private var showUnknown = false
    @State private var expandedTaskIDs: Set<String> = []
    @State private var contentHeight: CGFloat = 1
    @State private var headerHeight: CGFloat = 0
    @State private var footerHeight: CGFloat = 0
    @State private var screen = PanelScreenMetrics(visibleHeight: 800)
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.monitorOpaquePreview) private var opaquePreview

    init(store: MonitorStore, screenOverride: PanelScreenMetrics? = nil,
         initiallyExpandedTaskIDs: Set<String> = [], initiallyShowUnknown: Bool = false,
         onSizingChange: ((PanelSizing) -> Void)? = nil) {
        self.store = store
        self.screenOverride = screenOverride
        self.onSizingChange = onSizingChange
        _expandedTaskIDs = State(initialValue: initiallyExpandedTaskIDs)
        _showUnknown = State(initialValue: initiallyShowUnknown)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self, of: { ceil($0.size.height) }) { headerHeight = $0 }
                .accessibilityIdentifier("monitor.header")
            ScrollView {
                // Eager layout is intentional: measure the one real content tree,
                // including offscreen rows and disclosures, not a lazy estimate.
                VStack(alignment: .leading, spacing: 16) {
                    tasksSection
                    quotaSection
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
            PanelWindowReader(onChange: { screen = $0 }, onVisibilityChange: { store.setPanelVisible($0) })
                .allowsHitTesting(false)
        }
        .environment(\.monitorPanelActive, store.panelVisible || store.isPreview)
        .foregroundStyle(.primary)
        .onChange(of: sizing, initial: true) { _, value in onSizingChange?(value) }
        .onChange(of: store.tasks.map(\.id)) { _, ids in
            expandedTaskIDs.formIntersection(ids)
        }
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

    private var header: some View {
        HStack(spacing: 11) {
            VeyraIcon(size: 28)
            VStack(alignment: .leading, spacing: 3) {
                VeyraWordmark(width: 56)
                HStack(spacing: 5) {
                    Circle().fill(store.taskError == nil ? monitorAccent : .orange).frame(width: 5, height: 5)
                    Text("本机活动").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if store.quotaBusy || store.tasksBusy {
                ProgressView().controlSize(.small).scaleEffect(0.8)
            }
            Button { Task { await store.refreshAll() } } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary).frame(width: 18, height: 18)
            }
            .modifier(MonitorActionStyle())
            .help("刷新本地任务与额度快照")
            .accessibilityLabel("刷新")
            .accessibilityIdentifier("monitor.refresh")
            .disabled(store.tasksBusy)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var quotaSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                sectionTitle("额度")
                Spacer()
                if let plan = store.quota.account?.plan {
                    Text(plan.uppercased()).font(.system(size: 9, weight: .semibold, design: .rounded))
                        .tracking(0.5).padding(.horizontal, 7).padding(.vertical, 4)
                        .background(.primary.opacity(0.08), in: Capsule()).foregroundStyle(.secondary)
                }
            }
            if let snapshot = store.quota.snapshot, !snapshot.windows.isEmpty {
                let bucketIDs = snapshot.windows.reduce(into: [String]()) { ids, window in
                    if !ids.contains(window.bucketID) { ids.append(window.bucketID) }
                }
                ForEach(bucketIDs, id: \.self) { id in
                    let windows = snapshot.windows.filter { $0.bucketID == id }
                    VStack(alignment: .leading, spacing: 10) {
                        Text(windows.first?.bucketName ?? id)
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(.primary)
                        VStack(spacing: 12) {
                            ForEach(windows) { window in QuotaWindowView(window: window) }
                        }
                        MonitorTimeline(interval: 30) { now in
                            VStack(alignment: .leading, spacing: 3) {
                                Text("\(snapshot.source == .local ? "本地快照" : "联网校准") · \(snapshot.recordedAt(for: id).formatted(date: .abbreviated, time: .standard))")
                                if snapshot.isStale(bucketID: id, at: now) { Text("等待 Codex 更新").foregroundStyle(.orange) }
                            }.font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                    .padding(14).monitorCard()
                }
            } else if store.quotaBusy {
                HStack(spacing: 9) {
                    ProgressView().controlSize(.small)
                    Text("正在联网校准额度…").font(.system(size: 12)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, minHeight: 56).monitorCard()
            } else {
                Text("暂无本地额度记录").font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 44).monitorCard()
            }
            MonitorTimeline(interval: 1, enabled: store.nextCalibrationAt != nil, deadline: store.nextCalibrationAt) { now in
                HStack {
                    Button("联网校准") { Task { await store.calibrateQuota() } }
                        .disabled(store.quotaBusy || store.nextCalibrationAt.map { now < $0 } == true)
                        .accessibilityIdentifier("monitor.calibrate")
                    if let next = store.nextCalibrationAt, next > now {
                        Text("\(next.formatted(date: .omitted, time: .standard)) 后可校准")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
            }
            if let warning = store.localQuotaWarning { notice(warning) }
            if let error = store.quota.error { notice(error) }
            VStack(alignment: .leading, spacing: 4) {
                if store.quota.snapshot?.source == .local {
                    Text("本机会话记录 · 账号归属未确认 · 菜单栏 ~ 表示本地快照")
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let email = store.quota.account?.email { Text(email).lineLimit(1).help(email) }
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private var tasksSection: some View {
        let groups = TaskGroup.make(tasks: store.tasks, ancestors: store.taskAncestors)
        let runningGroups = groups.filter(\.isRunning)
        let unknownGroups = groups.filter { !$0.isRunning }
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                sectionTitle("运行任务")
                Text("\(store.runningTasks.count)")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary).padding(.horizontal, 7).padding(.vertical, 3)
                    .background(.primary.opacity(0.08), in: Capsule())
                Spacer()
                Text("每 \(store.pollingSeconds) 秒检查").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if store.runningTasks.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: !store.hasTaskSnapshot ? "ellipsis" : "checkmark.circle")
                        .font(.system(size: 20, weight: .light)).foregroundStyle(.tertiary)
                    Text(!store.hasTaskSnapshot && store.taskError == nil ? "正在读取本机任务…" : "暂无已确认运行的任务")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity).padding(.vertical, 16).monitorCard()
            } else {
                ForEach(runningGroups) { group in
                    TaskGroupCard(group: group, expansion: expandedBinding)
                }
            }
            if !unknownGroups.isEmpty {
                DisclosureGroup(isExpanded: $showUnknown) {
                    VStack(spacing: 10) {
                        Text("记录尚未结束，但无法确认仍有进程运行。不会计入顶部运行数。")
                            .font(.system(size: 11)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                        ForEach(unknownGroups) { group in TaskGroupCard(group: group, expansion: expandedBinding) }
                    }.padding(.top, 10)
                } label: {
                    Label("状态待确认 · \(unknownGroups.reduce(0) { $0 + $1.unknownCount })", systemImage: "questionmark.circle")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            if let error = store.taskError { notice(error) }
            if let warning = store.taskWarning { notice(warning) }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Label("本机任务 · 额度快照", systemImage: "desktopcomputer")
                .font(.system(size: 11)).lineLimit(1)
            Spacer(minLength: 0)
            MonitorGlassGroup {
                HStack(spacing: 8) {
                    SettingsLink {
                        Image(systemName: "gearshape").font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.primary).frame(width: 18, height: 18)
                    }
                    .modifier(MonitorActionStyle())
                    .simultaneousGesture(TapGesture().onEnded { NSApp.activate(ignoringOtherApps: true) })
                    .help("设置").accessibilityLabel("设置")
                    .accessibilityIdentifier("monitor.settings")
                    Button { NSApplication.shared.terminate(nil) } label: {
                        Image(systemName: "power").font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.primary).frame(width: 18, height: 18)
                    }
                    .modifier(MonitorActionStyle())
                    .help("退出 Veyra").accessibilityLabel("退出")
                    .accessibilityIdentifier("monitor.quit")
                }
            }
        }.foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 12)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.primary)
    }
    private func notice(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.circle")
            .font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
    }
}

private struct QuotaWindowView: View {
    let window: QuotaWindow
    @Environment(\.monitorReferenceDate) private var referenceDate
    private var tint: Color {
        guard let remaining = window.remainingPercent else { return .secondary }
        return remaining <= 10 ? .red : remaining <= 25 ? .orange : .primary
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(durationTitle)
                        .font(.system(size: 13, weight: .medium))
                    resetLabel
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("剩余").font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(DisplayFormat.percent(window.remainingPercent))
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .monospacedDigit().foregroundStyle(tint)
                }.fixedSize()
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(tint.opacity(0.12))
                    if let remaining = window.remainingPercent {
                        Capsule().fill(tint).frame(width: max(0, geometry.size.width * remaining / 100))
                    }
                }
            }.frame(height: 5)
        }
        .accessibilityElement(children: .combine)
    }

    private var resetLabel: some View {
        Group {
            if let reset = window.resetsAt {
                MonitorTimeline(interval: 30) { now in
                    Text(reset > (referenceDate ?? now) ? "\(reset.formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour().minute())) 重置" : "已到重置时间 · 等待更新")
                }
            } else {
                Text("重置时间暂不可用")
            }
        }
        .font(.system(size: 11)).foregroundStyle(.secondary)
    }

    private var durationTitle: String {
        let label = window.durationLabel
        if label == "周" { return "每周额度" }
        return label.hasSuffix("额度") ? label : "\(label)额度"
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
                        TaskRow(task: task, parentTitle: row.parentTitle, expanded: expansion(task.id))
                    } else {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(row.reference.title).font(.system(size: 13, weight: .semibold))
                                .lineLimit(2).fixedSize(horizontal: false, vertical: true).help(row.reference.title)
                            Label("父任务", systemImage: "arrow.triangle.branch")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(14).padding(.leading, indent)
                .accessibilityElement(children: .contain)
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
    let parentTitle: String?
    @Binding var expanded: Bool
    @Environment(\.monitorReferenceDate) private var referenceDate
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(task.title).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true).help(task.title)
                    Text("\(task.sourceLabel) · \(task.model ?? "模型未知")")
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).help(task.model ?? "")
                }
                Spacer(minLength: 0)
                Circle().fill(task.activity == .running ? monitorAccent : .orange).frame(width: 6, height: 6).padding(.top, 5)
                    .accessibilityLabel(task.activity == .running ? "运行中" : "状态待确认")
            }
            if let progress = task.progress {
                Text("\(progress.label)：\(progress.text)")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true).help("\(progress.label)：\(progress.text)")
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    activitySummary.fixedSize()
                    Spacer(minLength: 4)
                    tokenButton.fixedSize()
                }
                VStack(alignment: .leading, spacing: 6) {
                    activitySummary
                    tokenButton.frame(maxWidth: .infinity, alignment: .trailing)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if expanded {
                Divider()
                if parentTitle != nil || task.agentPath != nil || task.agentNickname != nil || task.agentRole != nil {
                    VStack(alignment: .leading, spacing: 4) {
                        contextLine("来自", value: parentTitle)
                        contextLine("任务路径", value: task.agentPath)
                        contextLine("代理", value: task.agentNickname)
                        contextLine("角色", value: task.agentRole)
                    }
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Divider()
                }
                VStack(spacing: 6) {
                    tokenLine("输入", value: task.tokens.input)
                    tokenLine("其中缓存输入", value: task.tokens.cachedInput)
                    tokenLine("输出", value: task.tokens.output)
                    tokenLine("其中推理输出", value: task.tokens.reasoningOutput)
                    tokenLine("累计总量", value: task.tokens.total)
                    Text("缓存与推理明细已包含在总量中。")
                        .font(.system(size: 11)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    @ViewBuilder private func contextLine(_ label: String, value: String?) -> some View {
        if let value {
            Text("\(label)：\(value)").fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
    }

    private var activitySummary: some View {
        VStack(alignment: .leading, spacing: 4) {
            elapsedTime
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { inputTokens; outputTokens }
                VStack(alignment: .leading, spacing: 3) { inputTokens; outputTokens }
            }
            .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
        }
    }

    private var inputTokens: some View { Text("输入 \(DisplayFormat.tokens(task.tokens.input))") }
    private var outputTokens: some View { Text("输出 \(DisplayFormat.tokens(task.tokens.output))") }

    private var elapsedTime: some View {
        Group {
            if task.activity == .running {
                MonitorTimeline(interval: 1) { now in
                    Label(DisplayFormat.duration(since: task.startedAt, now: referenceDate ?? now), systemImage: "clock")
                }
            } else { Label("状态未知", systemImage: "clock") }
        }.font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
    }

    private var tokenButton: some View {
        Button { expanded.toggle() } label: {
            VStack(alignment: .trailing, spacing: 2) {
                Text("累计 tokens").font(.system(size: 11)).foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(DisplayFormat.tokens(task.tokens.total))
                        .font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }.buttonStyle(.plain).help("查看累计 token 明细")
        .accessibilityLabel("\(task.title)，累计 token 明细")
        .accessibilityValue(tokenAccessibilityValue)
        .accessibilityIdentifier("monitor.tokens.\(task.id)")
    }

    private var tokenAccessibilityValue: String {
        let usage = task.tokens.total.map { "累计 \(DisplayFormat.tokens($0)) tokens" } ?? "累计用量暂不可用"
        return "\(usage)，\(expanded ? "已展开" : "已收起")"
    }

    private func tokenLine(_ label: String, value: Int64?) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value.map { $0.formatted() } ?? "—").monospacedDigit()
        }.font(.system(size: 11))
    }
}

private extension View {
    func monitorCard() -> some View {
        modifier(ControlCenterTile())
    }
}

private struct MonitorPanelActiveKey: EnvironmentKey { static let defaultValue = false }
private extension EnvironmentValues {
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
