import AppKit
import SwiftUI

enum DashboardTaskSort: String, CaseIterable {
    case recent, duration, tokens
    var label: String {
        switch self {
        case .recent: L10n.text("Recent activity")
        case .duration: L10n.text("Cumulative duration")
        case .tokens: L10n.text("Tokens")
        }
    }
    func rows(_ rows: [DashboardTaskRow]) -> [DashboardTaskRow] {
        rows.sorted {
            if self == .recent { return false }
            let a = self == .duration ? $0.elapsed : $0.tokens.total.map(Double.init)
            let b = self == .duration ? $1.elapsed : $1.tokens.total.map(Double.init)
            return (a ?? -.infinity) > (b ?? -.infinity)
        }
    }
    func families(_ values: [DashboardFamily]) -> [DashboardFamily] {
        guard self != .recent else { return values }
        return values.sorted {
            let a = self == .duration ? $0.usage.endedDuration : $0.usage.tokens.map(Double.init)
            let b = self == .duration ? $1.usage.endedDuration : $1.usage.tokens.map(Double.init)
            if a != b { return (a ?? -.infinity) > (b ?? -.infinity) }
            return ($0.latestActivity ?? .distantPast) != ($1.latestActivity ?? .distantPast)
                ? ($0.latestActivity ?? .distantPast) > ($1.latestActivity ?? .distantPast) : $0.id < $1.id
        }
    }
}

struct DashboardWorkspaceView: View {
    @Bindable var store: DashboardStore
    @Binding var sort: DashboardTaskSort
    @State private var fraction: CGFloat = 0.48
    @State private var dragOrigin: CGFloat?

    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width + 56 >= 1180
            let selected = store.displayedFamilies.first { $0.id == store.selectedFamilyID }
            let hasSelection = store.selectedFamilyID != nil
            ZStack {
                HStack(spacing: 0) {
                    DashboardFamilyList(families: sort.families(store.displayedFamilies), runningIDs: store.global.runningIDs,
                                        attention: store.global.attention, selected: $store.selectedFamilyID, sort: $sort)
                        .frame(width: wide && hasSelection ? max(400, min(geometry.size.width - 560, geometry.size.width * fraction)) : nil)
                        .opacity(!wide && hasSelection ? 0 : 1)
                        .accessibilityHidden(!wide && hasSelection)
                        .allowsHitTesting(wide || !hasSelection)
                    if wide && hasSelection {
                        Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 5)
                            .contentShape(Rectangle())
                            .gesture(DragGesture().onChanged { value in
                                if dragOrigin == nil { dragOrigin = fraction }
                                fraction = max(0.3, min(0.65, (dragOrigin ?? fraction) + value.translation.width / geometry.size.width))
                            }.onEnded { _ in dragOrigin = nil })
                            .accessibilityLabel("Resize task details")
                            .accessibilityAdjustableAction { direction in
                                switch direction {
                                case .increment: fraction = min(0.65, fraction + 0.05)
                                case .decrement: fraction = max(0.3, fraction - 0.05)
                                @unknown default: break
                                }
                            }
                        DashboardSelectedTask(family: selected, interval: store.detailInterval,
                                              selectedTurn: store.selectedTurnID, running: selected.map { store.global.runningIDs.contains($0.id) } ?? false,
                                              reason: store.global.attention.first { $0.id == selected?.id }?.reasons.first,
                                              close: { store.selectedFamilyID = nil }, back: false)
                            .frame(maxWidth: .infinity)
                    }
                }
                if !wide && hasSelection {
                    DashboardSelectedTask(family: selected, interval: store.detailInterval,
                                          selectedTurn: store.selectedTurnID, running: selected.map { store.global.runningIDs.contains($0.id) } ?? false,
                                          reason: store.global.attention.first { $0.id == selected?.id }?.reasons.first,
                                          close: { store.selectedFamilyID = nil }, back: true)
                        .background(Color(nsColor: .textBackgroundColor))
                }
            }
        }.accessibilityIdentifier("dashboard.workspace")
    }
}

private struct DashboardFamilyList: View {
    let families: [DashboardFamily]
    let runningIDs: Set<String>
    let attention: [DashboardAttention]
    @Binding var selected: String?
    @Binding var sort: DashboardTaskSort
    @State private var scrollID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Work details").font(.headline)
                Text(families.count.formatted()).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                Picker("Sort", selection: $sort) {
                    ForEach(DashboardTaskSort.allCases, id: \.self) { Text($0.label).tag($0) }
                }.labelsHidden().frame(width: 155).accessibilityIdentifier("dashboard.sort")
            }.padding(.horizontal, 12).padding(.top, 12)
            if families.isEmpty {
                ContentUnavailableView(L10n.text("No matching tasks"), systemImage: "line.3.horizontal.decrease.circle",
                                       description: Text("Change the date or filters to see more tasks."))
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(projects, id: \.self) { project in
                        DashboardProjectGroup(project: project, families: families.filter { ($0.project ?? "") == project },
                                              runningIDs: runningIDs, attention: attention, selected: $selected)
                    }
                }.scrollTargetLayout()
            }.scrollPosition(id: $scrollID, anchor: .top)
                .accessibilityIdentifier("dashboard.taskList")
                .focusable()
                .onMoveCommand { direction in
                    guard !families.isEmpty else { return }
                    let current = selected.flatMap { id in families.firstIndex { $0.id == id } } ?? -1
                    let next: Int
                    switch direction {
                    case .down: next = min(families.count - 1, current + 1)
                    case .up: next = max(0, current - 1)
                    default: return
                    }
                    selected = families[next].id; scrollID = selected
                }
                .onChange(of: selected) { _, id in
                    if let id, families.contains(where: { $0.id == id }) { scrollID = id }
                }
        }
    }
    private var projects: [String] {
        var seen: Set<String> = []
        return families.compactMap { seen.insert($0.project ?? "").inserted ? $0.project ?? "" : nil }
    }
}

private struct DashboardProjectGroup: View {
    let project: String
    let families: [DashboardFamily]
    let runningIDs: Set<String>
    let attention: [DashboardAttention]
    @Binding var selected: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(project.isEmpty ? L10n.text("Unknown project") : URL(fileURLWithPath: project).lastPathComponent).fontWeight(.semibold)
                Text("\(families.count) tasks").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }.padding(.horizontal, 12).padding(.vertical, 9).background(Color.primary.opacity(0.035)).help(project)
            ForEach(families) { family in
                DashboardFamilyRow(family: family, running: runningIDs.contains(family.id),
                                   reason: attention.first { $0.id == family.id }?.reasons.first,
                                   selected: selected == family.id, select: { selected = family.id })
                    .id(family.id)
            }
        }.scrollTargetLayout()
    }
}

private struct DashboardFamilyRow: View {
    let family: DashboardFamily
    let running: Bool
    let reason: DashboardAttentionReason?
    let selected: Bool
    let select: () -> Void
    var body: some View {
        Button(action: select) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(family.title).font(.callout.weight(.medium)).lineLimit(2).foregroundStyle(.primary)
                    HStack(spacing: 5) {
                        Circle().fill(statusColor).frame(width: 6, height: 6)
                        Text(status).lineLimit(1)
                        if family.childCount > 0 { Text("· \(family.childCount) subtasks").lineLimit(1) }
                        if let date = family.latestActivity { Text(date, format: .dateTime.hour().minute()) }
                    }.font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .trailing, spacing: 3) {
                    Text(DisplayFormat.tokens(family.usage.tokens)).monospacedDigit()
                    Text(family.usage.incomplete ? "Partial usage" : "Token").font(.caption2).foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            }.padding(12).contentShape(Rectangle())
                .background(selected ? Color.accentColor.opacity(0.12) : .clear)
        }.buttonStyle(.plain).help(family.title)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier("dashboard.task.\(family.id)")
    }
    private var status: String {
        if running { return L10n.text("Currently running") }
        if let reason { return reason.label }
        let latest = family.rows.flatMap(\.turns).max { ($0.lastActivity ?? .distantPast) < ($1.lastActivity ?? .distantPast) }
        return latest?.result.label ?? L10n.text("No execution records in this range.")
    }
    private var statusColor: Color { running ? .accentColor : reason == .failed || reason == .interrupted ? .red : reason == .uncertain ? .orange : .secondary }
}

private struct DashboardSelectedTask: View {
    let family: DashboardFamily?
    let interval: DateInterval
    let selectedTurn: String?
    let running: Bool
    let reason: DashboardAttentionReason?
    let close: () -> Void
    let back: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button(action: close) { Label(back ? "Back to tasks" : "Close details", systemImage: back ? "chevron.left" : "xmark") }
                    .buttonStyle(.plain).accessibilityIdentifier("dashboard.closeDetails")
                Spacer()
                Text("Task details").font(.caption).foregroundStyle(.secondary)
            }.padding(16)
            if let family {
                DashboardTaskInspector(family: family, interval: interval, selectedTurn: selectedTurn,
                                       running: running, reason: reason).id(family.id)
            } else {
                ContentUnavailableView {
                    Label("Selected task is outside the current filters", systemImage: "line.3.horizontal.decrease.circle")
                } actions: { Button("Clear selection", action: close) }
            }
        }.accessibilityIdentifier("dashboard.taskDetails")
    }
}

private struct DashboardTaskInspector: View {
    let family: DashboardFamily
    let interval: DateInterval
    let selectedTurn: String?
    let running: Bool
    let reason: DashboardAttentionReason?
    @State private var result: ExecutionResult?
    @State private var showAll = false
    @State private var expandedTurn: String?
    @State private var showOpenFailure = false
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    DashboardTaskHeading(family: family, interval: interval, running: running, reason: reason, open: openTask)
                    DisclosureGroup {
                        ForEach(family.members.filter { $0.id != family.id }) { task in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(task.title).fontWeight(.medium)
                                Text(task.source).font(.caption).foregroundStyle(.secondary)
                            }.padding(.vertical, 4)
                        }
                    } label: { Text("Subtasks (\(family.childCount))") }
                    Divider()
                    HStack {
                        Text("Execution records").font(.headline)
                        Text(family.turnCount.formatted()).foregroundStyle(.secondary)
                        Spacer()
                        Picker("Result", selection: $result) {
                            Text("All results").tag(nil as ExecutionResult?)
                            ForEach(ExecutionResult.allCases, id: \.self) { Text($0.label).tag(Optional($0)) }
                        }.labelsHidden().frame(maxWidth: 170)
                    }
                    Text("Latest first · Current detail range").font(.caption).foregroundStyle(.secondary)
                    DashboardExecutionList(records: visibleRecords, interval: interval, expanded: $expandedTurn)
                    if records.count > 6 {
                        Button(showAll ? "Show recent rounds" : "View all rounds") { showAll.toggle() }
                            .buttonStyle(.link).accessibilityIdentifier("dashboard.allRounds")
                    }
                    DisclosureGroup("Task information") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(family.project ?? L10n.text("Unknown project"))
                            Text(family.id)
                            ForEach(family.members) { task in
                                Text(task.title + " · " + task.source)
                                if !task.sourceAvailable { Text("Source no longer available").foregroundStyle(.orange) }
                            }
                        }.font(.caption).textSelection(.enabled).padding(.top, 8)
                    }
                }.padding(.horizontal, 20).padding(.bottom, 20)
            }
            .task(id: selectedTurn) {
                guard let selectedTurn,
                      let match = records.first(where: { $0.id == selectedTurn || $0.turn.id == selectedTurn }) else { return }
                showAll = true; expandedTurn = match.id
                // The target may be outside the initial six lazy rows. Let the expanded
                // collection commit before asking ScrollViewReader to locate its stable ID.
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled else { return }
                proxy.scrollTo(match.id, anchor: .center)
            }
        }
        .alert("Unable to open this task", isPresented: $showOpenFailure) {
            Button("Copy task identifier") { copy(family.id) }
            Button("Cancel", role: .cancel) { }
        } message: { Text("Open Codex and locate the task using its identifier.") }
    }
    private var records: [DashboardExecutionRecord] {
        var values: [DashboardExecutionRecord] = []
        for row in family.rows {
            for turn in row.turns where result == nil || turn.result == result {
                values.append(DashboardExecutionRecord(taskID: row.id, title: row.task.title, source: row.task.source, turn: turn))
            }
        }
        return values.sorted { a, b in
            let left = a.turn.startedAt ?? a.turn.lastActivity ?? .distantPast
            let right = b.turn.startedAt ?? b.turn.lastActivity ?? .distantPast
            return left != right ? left > right : a.id < b.id
        }
    }
    private var visibleRecords: [DashboardExecutionRecord] { showAll ? records : Array(records.prefix(6)) }
    private func openTask() {
        guard let url = DashboardThreadLink.url(for: family.id),
              NSWorkspace.shared.urlForApplication(toOpen: url) != nil else { showOpenFailure = true; return }
        NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if error != nil { Task { @MainActor in showOpenFailure = true } }
        }
    }
}

private struct DashboardTaskHeading: View {
    let family: DashboardFamily
    let interval: DateInterval
    let running: Bool
    let reason: DashboardAttentionReason?
    let open: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(family.title).font(.title3.weight(.semibold)).textSelection(.enabled)
            HStack {
                Text(family.project.map { URL(fileURLWithPath: $0).lastPathComponent } ?? L10n.text("Unknown project")).foregroundStyle(.secondary)
                if running { Label("Currently running", systemImage: "circle.fill").font(.caption).foregroundStyle(Color.accentColor) }
                else if let reason { Text(reason.label).font(.caption).foregroundStyle(reason == .uncertain ? Color.orange : .red) }
                Spacer()
                Button("Open in Codex", systemImage: "arrow.up.right", action: open)
            }
            HStack(alignment: .top, spacing: 24) {
                DashboardValue(title: "Recorded Token usage", value: DisplayFormat.tokens(family.usage.tokens))
                DashboardValue(title: "Ended round duration", value: DashboardExport.duration(family.usage.endedDuration))
            }
            Text(summary).font(.caption).foregroundStyle(.secondary)
            if family.usage.missingTokens > 0 { Text("Usage incomplete: \(family.usage.missingTokens) rounds").font(.caption).foregroundStyle(.orange) }
            if family.usage.openTurns > 0 { Text("Open records do not establish that a task is currently running.").font(.caption).foregroundStyle(.secondary) }
        }
    }
    private var summary: String {
        let turns = family.rows.flatMap(\.turns)
        return ExecutionResult.allCases.compactMap { result -> String? in
            let count = DashboardStatistics.resultCount(result, turns: turns, in: interval)
            return count > 0 ? result.label + ": " + count.formatted() : nil
        }.joined(separator: " · ")
    }
}

struct DashboardValue: View {
    let title: LocalizedStringKey
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 26, weight: .semibold)).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct DashboardExecutionRecord: Identifiable {
    let taskID: String
    let title: String
    let source: String
    let turn: HistoryTurn
    var id: String { taskID + ":" + turn.id }
}

private struct DashboardExecutionList: View {
    let records: [DashboardExecutionRecord]
    let interval: DateInterval
    @Binding var expanded: String?
    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Time").frame(maxWidth: .infinity, alignment: .leading)
                Text("Result").frame(width: 100, alignment: .leading)
                Text("Duration").frame(width: 72, alignment: .trailing)
                Text("Token").frame(width: 76, alignment: .trailing)
            }.font(.caption).foregroundStyle(.secondary).padding(.vertical, 8)
            ForEach(records) { record in
                DashboardExecutionRow(record: record, interval: interval, expanded: expanded == record.id,
                                      toggle: { expanded = expanded == record.id ? nil : record.id },
                                      showDate: firstRecordOnDay(record), sharedModel: sharedModel)
                    .id(record.id)
            }
            if records.isEmpty { Text("No execution records in this range.").foregroundStyle(.secondary).padding(.vertical) }
        }
    }
    private var sharedModel: String? {
        let models = Set(records.compactMap { $0.turn.model })
        return models.count == 1 && records.allSatisfy { $0.turn.model != nil } ? models.first : nil
    }
    private func firstRecordOnDay(_ record: DashboardExecutionRecord) -> Bool {
        guard let index = records.firstIndex(where: { $0.id == record.id }) else { return false }
        guard index > 0, let date = record.turn.startedAt ?? record.turn.lastActivity,
              let before = records[index - 1].turn.startedAt ?? records[index - 1].turn.lastActivity else { return true }
        return !Calendar.autoupdatingCurrent.isDate(date, inSameDayAs: before)
    }
}

private struct DashboardExecutionRow: View {
    let record: DashboardExecutionRecord
    let interval: DateInterval
    let expanded: Bool
    let toggle: () -> Void
    let showDate: Bool
    let sharedModel: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showDate {
                HStack {
                    if let date = record.turn.startedAt ?? record.turn.lastActivity { Text(date, format: .dateTime.year().month().day()) }
                    if let sharedModel { Text(sharedModel).foregroundStyle(.secondary) }
                }.font(.caption).padding(.vertical, 10)
            }
            Divider()
            Button(action: toggle) {
                HStack(spacing: 8) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.caption2).frame(width: 10)
                    Text(timeRange).frame(maxWidth: .infinity, alignment: .leading)
                    Text(record.turn.result.label).foregroundStyle(resultColor).frame(width: 100, alignment: .leading)
                    Text(DashboardExport.duration(record.turn.elapsed(in: interval))).frame(width: 72, alignment: .trailing)
                    Text(DisplayFormat.tokens(usage.tokens)).frame(width: 76, alignment: .trailing)
                }.font(.caption).monospacedDigit().padding(.vertical, 10).contentShape(Rectangle())
            }.buttonStyle(.plain)
            if expanded {
                VStack(alignment: .leading, spacing: 7) {
                    Text(record.title).fontWeight(.medium)
                    Text("Started: \(record.turn.startedAt?.formatted(date: .numeric, time: .standard) ?? "—")")
                    Text("Ended: \(record.turn.endedAt?.formatted(date: .numeric, time: .standard) ?? "—")")
                    Text((record.turn.model ?? L10n.text("Unknown model")) + " · " + record.source)
                    let raw = DashboardStatistics.tokens(record.turn, in: interval)
                    Text(L10n.text("Input tokens") + ": " + DisplayFormat.tokens(raw.input) + " · " + L10n.text("Output tokens") + ": " + DisplayFormat.tokens(raw.output))
                    Text(L10n.text("Cached input tokens") + ": " + DisplayFormat.tokens(raw.cachedInput))
                    if usage.incomplete { Text("Partial usage").foregroundStyle(.orange) }
                    if !record.turn.sourceAvailable { Text("Source no longer available").foregroundStyle(.orange) }
                    Button("Copy record information", systemImage: "doc.on.doc") {
                        copy([record.title, timeRange, record.turn.result.label, record.turn.model ?? "—", record.source,
                              DisplayFormat.tokens(usage.tokens)].joined(separator: "\n"))
                    }.buttonStyle(.link)
                }.font(.caption).textSelection(.enabled).padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.025))
            } else if sharedModel == nil {
                Text(record.turn.model ?? L10n.text("Unknown model")).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
    private var usage: DashboardUsage {
        DashboardUsage.summarize([DashboardTaskRow(task: HistoryTask(id: record.taskID, title: record.title, source: record.source),
            turns: [record.turn], elapsed: nil, tokens: HistoryTokens())], in: interval)
    }
    private var timeRange: String {
        let start = record.turn.startedAt?.formatted(date: .omitted, time: .shortened) ?? "—"
        let end = record.turn.endedAt.map { date in
            let same = record.turn.startedAt.map { Calendar.current.isDate($0, inSameDayAs: date) } ?? false
            return date.formatted(date: same ? .omitted : .abbreviated, time: .shortened)
        } ?? "—"
        return start + " – " + end
    }
    private var resultColor: Color { record.turn.result == .failed || record.turn.result == .interrupted ? .red : record.turn.result == .running || record.turn.result == .unknown ? .orange : .primary }
}

private func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}
