import SwiftUI

private let monitorAccent = Color(nsColor: .systemGreen)

struct MonitorPanel: View {
    @Bindable var store: MonitorStore
    var updates: UpdateStore?
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

    init(store: MonitorStore, updates: UpdateStore? = nil, screenOverride: PanelScreenMetrics? = nil,
         initiallyExpandedTaskIDs: Set<String> = [], initiallyShowUnknown: Bool = false,
         onSizingChange: ((PanelSizing) -> Void)? = nil) {
        self.store = store
        self.updates = updates
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
            PanelWindowReader(onChange: { screen = $0 }, onVisibilityChange: { visible in
                store.setPanelVisible(visible)
                if visible, !store.isPreview { Task { await updates?.checkAutomatically() } }
            })
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
            VeyraWordmark(width: 56)
            Spacer()
            HStack(spacing: 5) {
                Circle().fill(store.taskError == nil ? monitorAccent : .orange).frame(width: 5, height: 5)
                Text("Local activity").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var quotaSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                sectionTitle("Quota")
                if store.quotaBusy {
                    ProgressView().controlSize(.small).scaleEffect(0.8)
                        .frame(width: 14, height: 14)
                        .accessibilityLabel("Syncing quota online")
                        .accessibilityIdentifier("monitor.quotaProgress")
                }
                Spacer()
                if let plan = store.quota.account?.plan {
                    Text(plan.uppercased()).font(.system(size: 9, weight: .semibold, design: .rounded))
                        .tracking(0.5).padding(.horizontal, 7).padding(.vertical, 4)
                        .background(.primary.opacity(0.08), in: Capsule()).foregroundStyle(.secondary)
                }
                MonitorTimeline(interval: 1, enabled: store.nextCalibrationAt != nil, deadline: store.nextCalibrationAt) { now in
                    HStack(spacing: 7) {
                        if let next = store.nextCalibrationAt, next > now {
                            Text(L10n.text("Sync after \(next.formatted(date: .omitted, time: .standard))"))
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        Button { Task { await store.calibrateQuota() } } label: {
                            Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.primary).frame(width: 18, height: 18)
                        }
                        .modifier(MonitorActionStyle())
                        .help("Sync quota online")
                        .accessibilityLabel("Sync quota")
                        .accessibilityIdentifier("monitor.calibrate")
                        .disabled(store.quotaBusy || store.nextCalibrationAt.map { now < $0 } == true)
                    }
                }
            }
            ResetCreditsCard(snapshot: store.quota.resetCredits, isLoading: store.quotaBusy)
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
                            ForEach(windows) { window in
                                if window.id != windows.first?.id {
                                    Divider().accessibilityHidden(true)
                                }
                                QuotaWindowView(window: window)
                            }
                        }
                        Text(L10n.text("\(snapshot.source(for: id) == .local ? L10n.text("Local snapshot") : L10n.text("Online sync")) · \(snapshot.recordedAt(for: id).formatted(date: .abbreviated, time: .standard))"))
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    .padding(14).monitorCard()
                }
            } else if store.quotaBusy {
                HStack(spacing: 9) {
                    ProgressView().controlSize(.small)
                    Text("Syncing quota online…").font(.system(size: 12)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, minHeight: 56).monitorCard()
            } else {
                Text("No local quota records").font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 44).monitorCard()
            }
            if let warning = store.localQuotaWarning { notice(warning) }
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
                Text("\(store.runningTasks.count)")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary).padding(.horizontal, 7).padding(.vertical, 3)
                    .background(.primary.opacity(0.08), in: Capsule())
                if store.tasksBusy {
                    ProgressView().controlSize(.small).scaleEffect(0.8)
                        .frame(width: 14, height: 14)
                        .accessibilityLabel("Refreshing running tasks")
                        .accessibilityIdentifier("monitor.tasksProgress")
                }
                Spacer()
                PollingInfoView(seconds: store.pollingSeconds)
                Button { Task { await store.refreshAll() } } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary).frame(width: 18, height: 18)
                }
                .modifier(MonitorActionStyle())
                .help("Refresh local tasks and quota snapshots")
                .accessibilityLabel("Refresh")
                .accessibilityIdentifier("monitor.refresh")
                .disabled(store.tasksBusy)
            }
            .zIndex(1)
            if store.runningTasks.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: !store.hasTaskSnapshot ? "ellipsis" : "checkmark.circle")
                        .font(.system(size: 20, weight: .light)).foregroundStyle(.tertiary)
                    Text(!store.hasTaskSnapshot && store.taskError == nil ? L10n.text("Reading local tasks…") : L10n.text("No confirmed running tasks"))
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
                        Text("These sessions have not ended, but no running process could be confirmed. They are excluded from the running count.")
                            .font(.system(size: 11)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                        ForEach(unknownGroups) { group in TaskGroupCard(group: group, expansion: expandedBinding) }
                    }.padding(.top, 10)
                } label: {
                    Label(L10n.text("Unconfirmed status · \(unknownGroups.reduce(0) { $0 + $1.unknownCount })"), systemImage: "questionmark.circle")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            if let error = store.taskError { notice(error) }
            if let warning = store.taskWarning { notice(warning.message) }
        }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            if let release = updates?.availableRelease {
                HStack(spacing: 8) {
                    Text(L10n.text("New version available: \(release.version)"))
                        .font(.system(size: 11, weight: .medium))
                    Spacer(minLength: 4)
                    UpdateDownloadLink(release: release).font(.system(size: 11))
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .accessibilityIdentifier("updates.banner")
                Divider()
            }
            footerActions
        }
    }

    private var footerActions: some View {
        HStack(spacing: 8) {
            Label("Local tasks · Quota snapshots", systemImage: "desktopcomputer")
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
                    .help("Settings").accessibilityLabel("Settings")
                    .accessibilityIdentifier("monitor.settings")
                    Button { NSApplication.shared.terminate(nil) } label: {
                        Image(systemName: "power").font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.primary).frame(width: 18, height: 18)
                    }
                    .modifier(MonitorActionStyle())
                    .help("Quit Veyra").accessibilityLabel("Quit")
                    .accessibilityIdentifier("monitor.quit")
                }
            }
        }.foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 12)
    }

    private func sectionTitle(_ title: LocalizedStringKey) -> some View {
        Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.primary)
    }
    private func notice(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.circle")
            .font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
    }
}

private struct PollingInfoView: View {
    let seconds: Int
    @State private var isHovered = false
    @Environment(\.monitorPanelActive) private var panelActive

    private var tooltip: String { L10n.text("Checks every \(seconds) seconds") }

    var body: some View {
        Image(systemName: "info.circle")
            .font(.system(size: 13)).foregroundStyle(.secondary)
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
            .accessibilityLabel("Automatic check interval")
            .accessibilityValue(tooltip)
            .accessibilityIdentifier("monitor.pollingInfo")
            .overlay(alignment: .topTrailing) {
                if isHovered {
                    Text(tooltip)
                        .font(.system(size: 11)).foregroundStyle(.primary)
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
                        .overlay {
                            RoundedRectangle(cornerRadius: 5)
                                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
                        }
                        .fixedSize()
                        .offset(y: 26)
                        .allowsHitTesting(false)
                        .accessibilityIdentifier("monitor.pollingTooltip")
                }
            }
            .onChange(of: panelActive) { _, active in
                if !active { isHovered = false }
            }
            .onDisappear { isHovered = false }
    }
}

private struct QuotaWindowView: View {
    let window: QuotaWindow
    @Environment(\.monitorReferenceDate) private var referenceDate

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(window.durationTitle)
                    .font(.system(size: 13, weight: .medium))
                resetLabel
            }
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
                    Text(reset > (referenceDate ?? now) ? L10n.text("Resets \(reset.formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour().minute()))") : L10n.text("Reset due · Awaiting update"))
                }
            } else {
                Text("Reset time unavailable")
            }
        }
        .font(.system(size: 11)).foregroundStyle(.secondary)
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
                        TaskRow(task: task, parentTitle: row.parentTitle, expanded: expansion(task.id))
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
                    Text("\(task.sourceLabel) · \(task.model ?? L10n.text("Unknown model"))")
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).help(task.model ?? "")
                }
                Spacer(minLength: 0)
                Circle().fill(task.activity == .running ? monitorAccent : .orange).frame(width: 6, height: 6).padding(.top, 5)
                    .accessibilityLabel(task.activity == .running ? L10n.text("Running") : L10n.text("Unconfirmed status"))
            }
            if let progress = task.progress {
                Text(L10n.text("\(progress.label): \(progress.text)"))
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true).help(L10n.text("\(progress.label): \(progress.text)"))
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
                        contextLine(L10n.text("From"), value: parentTitle)
                        contextLine(L10n.text("Task path"), value: task.agentPath)
                        contextLine(L10n.text("Agent"), value: task.agentNickname)
                        contextLine(L10n.text("Role"), value: task.agentRole)
                    }
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Divider()
                }
                VStack(spacing: 6) {
                    tokenLine("Input", value: task.tokens.input)
                    tokenLine("Cached input (included)", value: task.tokens.cachedInput,
                              percent: task.tokens.cachedInputPercent)
                    tokenLine("Output", value: task.tokens.output)
                    tokenLine("Reasoning output (included)", value: task.tokens.reasoningOutput)
                    tokenLine("Total usage", value: task.tokens.total)
                    Text("Cached input and reasoning output are included in the totals.")
                        .font(.system(size: 11)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    @ViewBuilder private func contextLine(_ label: String, value: String?) -> some View {
        if let value {
            Text(L10n.text("\(label): \(value)")).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
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

    private var inputTokens: some View { Text(L10n.text("Input \(DisplayFormat.tokens(task.tokens.input))")) }
    private var outputTokens: some View { Text(L10n.text("Output \(DisplayFormat.tokens(task.tokens.output))")) }

    private var elapsedTime: some View {
        Group {
            if task.activity == .running {
                MonitorTimeline(interval: 1) { now in
                    Label(DisplayFormat.duration(since: task.startedAt, now: referenceDate ?? now), systemImage: "clock")
                }
            } else { Label("Unknown status", systemImage: "clock") }
        }.font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
    }

    private var tokenButton: some View {
        Button { expanded.toggle() } label: {
            VStack(alignment: .trailing, spacing: 2) {
                Text("Total tokens").font(.system(size: 11)).foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(DisplayFormat.tokens(task.tokens.total))
                        .font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }.buttonStyle(.plain).help("View total token breakdown")
        .accessibilityLabel(L10n.text("\(task.title), total token breakdown"))
        .accessibilityValue(tokenAccessibilityValue)
        .accessibilityIdentifier("monitor.tokens.\(task.id)")
    }

    private var tokenAccessibilityValue: String {
        let usage = task.tokens.total.map { L10n.text("\(DisplayFormat.tokens($0)) tokens total") } ?? L10n.text("Total usage unavailable")
        return L10n.text("\(usage), \(expanded ? L10n.text("Expanded") : L10n.text("Collapsed"))")
    }

    private func tokenLine(_ label: LocalizedStringKey, value: Int64?, percent: Double? = nil) -> some View {
        let suffix = percent.map { " (\($0.formatted(.number.precision(.fractionLength(1))))%)" } ?? ""
        return HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text((value.map { $0.formatted() } ?? "—") + suffix).monospacedDigit()
        }.font(.system(size: 11))
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
                    detail(L10n.text("Last online sync · \(snapshot.fetchedAt.formatted(date: .abbreviated, time: .standard))"))
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
            Text(group.isExpired(at: now) ? L10n.text("Expired · Sync needed") : L10n.text("Expires \(expiry.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits).hour().minute()))"))
                .help(L10n.text("Expires: \(expiry.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits).hour().minute().second()))"))
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
