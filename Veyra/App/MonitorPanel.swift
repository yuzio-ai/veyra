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
        .background { PanelWindowReader { screen = $0 }.allowsHitTesting(false) }
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
            .help("刷新额度与任务")
            .accessibilityLabel("刷新")
            .accessibilityIdentifier("monitor.refresh")
            .disabled(store.quotaBusy && store.tasksBusy)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var quotaSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                sectionTitle("账号额度")
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
                    }
                    .padding(14).monitorCard()
                }
            } else if store.quotaBusy {
                HStack(spacing: 9) {
                    ProgressView().controlSize(.small)
                    Text("正在读取账号额度…").font(.system(size: 12)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, minHeight: 56).monitorCard()
            }
            if let error = store.quota.error { notice(error) }
            VStack(alignment: .leading, spacing: 4) {
                if let snapshot = store.quota.snapshot, !snapshot.windows.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: store.quota.error == nil ? "clock" : "exclamationmark.circle")
                        Text("更新于 \(snapshot.fetchedAt.formatted(date: .omitted, time: .standard))")
                        if store.quota.error != nil { Text("· 上次数据") }
                    }
                }
                if let email = store.quota.account?.email { Text(email).lineLimit(1).help(email) }
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private var tasksSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                sectionTitle("运行任务")
                Text("\(store.runningTasks.count)")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary).padding(.horizontal, 7).padding(.vertical, 3)
                    .background(.primary.opacity(0.08), in: Capsule())
                Spacer()
                Text("每 5 秒更新").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if store.runningTasks.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: store.tasksUpdatedAt == nil ? "ellipsis" : "checkmark.circle")
                        .font(.system(size: 20, weight: .light)).foregroundStyle(.tertiary)
                    Text(store.tasksUpdatedAt == nil && store.taskError == nil ? "正在读取本机任务…" : "暂无已确认运行的任务")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity).padding(.vertical, 16).monitorCard()
            } else {
                ForEach(orderedTasks(store.runningTasks), id: \.task.id) { entry in
                    TaskRow(task: entry.task, expanded: expandedBinding(for: entry.task.id))
                        .padding(.leading, CGFloat(min(entry.depth, 3)) * 10)
                }
            }
            if !store.unknownTasks.isEmpty {
                DisclosureGroup(isExpanded: $showUnknown) {
                    VStack(spacing: 10) {
                        Text("记录尚未结束，但无法确认仍有进程运行。不会计入顶部运行数。")
                            .font(.system(size: 11)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                        ForEach(store.unknownTasks) { TaskRow(task: $0, expanded: expandedBinding(for: $0.id)) }
                    }.padding(.top, 10)
                } label: {
                    Label("状态待确认 · \(store.unknownTasks.count)", systemImage: "questionmark.circle")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            if let error = store.taskError { notice(error) }
            if let warning = store.taskWarning { notice(warning) }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Label("本机任务 · 账号共享额度", systemImage: "desktopcomputer")
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
    private func orderedTasks(_ tasks: [TaskSnapshot]) -> [(task: TaskSnapshot, depth: Int)] {
        let ids = Set(tasks.map(\.id))
        var result: [(TaskSnapshot, Int)] = [], seen: Set<String> = []
        func append(_ task: TaskSnapshot, depth: Int) {
            guard seen.insert(task.id).inserted else { return }
            result.append((task, depth))
            for child in tasks where child.parentID == task.id { append(child, depth: depth + 1) }
        }
        for task in tasks where task.parentID == nil || !ids.contains(task.parentID!) { append(task, depth: 0) }
        for task in tasks where !seen.contains(task.id) { append(task, depth: 0) }
        return result
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
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(reset > (referenceDate ?? context.date) ? "\(reset.formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour().minute())) 重置" : "已到重置时间 · 等待更新")
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

private struct TaskRow: View {
    let task: TaskSnapshot
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
        }.padding(14).monitorCard()
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
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Label(task.activity == .running ? DisplayFormat.duration(since: task.startedAt, now: referenceDate ?? context.date) : "状态未知", systemImage: "clock")
                .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
        }
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
