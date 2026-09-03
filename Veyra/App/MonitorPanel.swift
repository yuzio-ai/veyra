import SwiftUI

private let monitorAccent = Color(nsColor: .systemGreen)

struct MonitorPanel: View {
    @Bindable var store: MonitorStore
    @State private var showUnknown = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.monitorOpaquePreview) private var opaquePreview

    var body: some View {
        MonitorGlassGroup {
            VStack(spacing: 0) {
                header
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        tasksSection
                        quotaSection
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 16)
                }
                // An explicit height keeps MenuBarExtra from collapsing the
                // scroll area when measuring its own ideal size.
                .frame(height: contentHeight)
                .scrollIndicators(.visible)
                footer
            }
        }
        .frame(width: 420)
        .background {
            if reduceTransparency || opaquePreview { Color(nsColor: .windowBackgroundColor) }
            else { MonitorBackdrop() }
        }
        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous)
            .strokeBorder(.primary.opacity(0.1), lineWidth: 0.5))
        .foregroundStyle(.primary)
    }

    private var contentHeight: CGFloat {
        min(540, max(240, (NSScreen.main?.visibleFrame.height ?? 800) - 180))
    }

    private var header: some View {
        HStack(spacing: 11) {
            VeyraIcon(size: 38)
            VStack(alignment: .leading, spacing: 3) {
                VeyraWordmark()
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
                    .foregroundStyle(.primary).frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .modifier(ControlCenterTile(cornerRadius: 17, interactive: true))
            .help("刷新额度与任务")
            .accessibilityLabel("刷新")
            .disabled(store.quotaBusy && store.tasksBusy)
        }
        .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 14)
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
                    VStack(alignment: .leading, spacing: 13) {
                        Text(windows.first?.bucketName ?? id).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                        ForEach(windows) { window in QuotaWindowView(window: window) }
                    }
                    .padding(18).monitorCard()
                }
                HStack(spacing: 4) {
                    Image(systemName: store.quota.error == nil ? "clock" : "exclamationmark.circle")
                    Text("更新于 \(snapshot.fetchedAt.formatted(date: .omitted, time: .standard))")
                    if store.quota.error != nil { Text("· 上次数据") }
                }
                .font(.system(size: 10)).foregroundStyle(.secondary)
            } else if store.quotaBusy {
                HStack(spacing: 9) {
                    ProgressView().controlSize(.small)
                    Text("正在读取账号额度…").font(.system(size: 12)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, minHeight: 70).monitorCard()
            }
            if let error = store.quota.error { notice(error) }
            if let email = store.quota.account?.email {
                Text(email).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
            }
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
                Text("每 5 秒更新").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            if store.runningTasks.isEmpty {
                VStack(spacing: 9) {
                    Image(systemName: store.tasksUpdatedAt == nil ? "ellipsis" : "checkmark.circle")
                        .font(.system(size: 23, weight: .light)).foregroundStyle(.tertiary)
                    Text(store.tasksUpdatedAt == nil && store.taskError == nil ? "正在读取本机任务…" : "暂无已确认运行的任务")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity).padding(.vertical, 25).monitorCard()
            } else {
                ForEach(orderedTasks(store.runningTasks), id: \.task.id) { entry in
                    TaskRow(task: entry.task)
                        .padding(.leading, CGFloat(min(entry.depth, 3)) * 14)
                }
            }
            if !store.unknownTasks.isEmpty {
                DisclosureGroup(isExpanded: $showUnknown) {
                    VStack(spacing: 10) {
                        Text("记录尚未结束，但无法确认仍有进程运行。不会计入顶部运行数。")
                            .font(.system(size: 11)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                        ForEach(store.unknownTasks) { TaskRow(task: $0) }
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
        HStack {
            Image(systemName: "desktopcomputer").font(.system(size: 10))
            Text("本机任务 · 账号共享额度").font(.system(size: 10))
            Spacer()
            SettingsLink {
                Image(systemName: "gearshape").font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.primary).frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .modifier(ControlCenterTile(cornerRadius: 17, interactive: true))
            .simultaneousGesture(TapGesture().onEnded { NSApp.activate(ignoringOtherApps: true) })
            .help("设置").accessibilityLabel("设置")
            Button { NSApplication.shared.terminate(nil) } label: {
                Image(systemName: "power").font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.primary).frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .modifier(ControlCenterTile(cornerRadius: 17, interactive: true))
            .help("退出 Veyra").accessibilityLabel("退出")
        }.foregroundStyle(.secondary).padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 14)
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
    private var tint: Color {
        guard let remaining = window.remainingPercent else { return .secondary }
        return remaining <= 10 ? .red : remaining <= 25 ? .orange : .primary
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.durationLabel == "周" ? "每周额度" : "\(window.durationLabel)额度")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("剩余").font(.system(size: 10)).foregroundStyle(.secondary)
                Text(DisplayFormat.percent(window.remainingPercent))
                    .font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(tint.opacity(0.12))
                    if let remaining = window.remainingPercent {
                        Capsule().fill(tint).frame(width: max(0, geometry.size.width * remaining / 100))
                    }
                }
            }.frame(height: 7)
            if let reset = window.resetsAt {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(reset > context.date ? "\(reset.formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour().minute())) 重置" : "已到重置时间 · 等待更新")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            } else {
                Text("重置时间暂不可用").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct TaskRow: View {
    let task: TaskSnapshot
    @State private var expanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(task.title).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true).help(task.title)
                    Text("\(task.sourceLabel) · \(task.model ?? "模型未知")")
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).help(task.model ?? "")
                }
                Spacer(minLength: 0)
                Circle().fill(task.activity == .running ? monitorAccent : .orange).frame(width: 6, height: 6).padding(.top, 5)
            }
            HStack(alignment: .firstTextBaseline) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Label(task.activity == .running ? DisplayFormat.duration(since: task.startedAt, now: context.date) : "状态未知", systemImage: "clock")
                        .font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer()
                Button { expanded.toggle() } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("累计").font(.system(size: 10)).foregroundStyle(.secondary)
                        Text(DisplayFormat.tokens(task.tokens.total)).font(.system(size: 20, weight: .semibold, design: .rounded))
                        Text("tokens").font(.system(size: 10)).foregroundStyle(.secondary)
                        Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(.tertiary)
                    }
                }.buttonStyle(.plain).help("查看累计 token 明细")
            }
            HStack(spacing: 14) {
                Text("输入 \(DisplayFormat.tokens(task.tokens.input))")
                Text("输出 \(DisplayFormat.tokens(task.tokens.output))")
            }
            .font(.system(size: 10))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            if expanded {
                Divider()
                VStack(spacing: 6) {
                    tokenLine("输入", value: task.tokens.input)
                    tokenLine("其中缓存输入", value: task.tokens.cachedInput)
                    tokenLine("输出", value: task.tokens.output)
                    tokenLine("其中推理输出", value: task.tokens.reasoningOutput)
                    tokenLine("累计总量", value: task.tokens.total)
                    Text("缓存与推理明细已包含在总量中。")
                        .font(.system(size: 9)).foregroundStyle(.tertiary).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }.padding(18).monitorCard()
    }
    private func tokenLine(_ label: String, value: Int64?) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value.map { $0.formatted() } ?? "—").monospacedDigit()
        }.font(.system(size: 10))
    }
}

private extension View {
    func monitorCard() -> some View {
        modifier(ControlCenterTile())
    }
}
