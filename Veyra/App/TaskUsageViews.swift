import SwiftUI

struct TaskContextUsageView: View {
    let taskID: String
    let usage: ContextWindowUsage?
    @Environment(\.locale) private var locale
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.monitorPreviewContrast) private var previewContrast

    private var percent: String {
        usage.map { $0.percent.formatted(.number.locale(locale).precision(.fractionLength(0))) + "%" } ?? "—"
    }
    private var counts: String {
        guard let usage else { return "— / —" }
        return "\(DisplayFormat.tokens(usage.used)) / \(DisplayFormat.tokens(usage.window))"
    }
    private var help: String {
        let note = L10n.text("Latest recorded context usage, updated with token statistics. Uses the reported window without a fixed baseline deduction; may differ from Codex's percentage.")
        guard let usage else { return note }
        let exact = L10n.text("\(TaskTokenText.count(usage.used)) / \(TaskTokenText.count(usage.window)) tokens")
        guard let date = usage.recordedAt else { return L10n.text("\(exact). \(note)") }
        let time = date.formatted(.dateTime.hour().minute().second().locale(locale))
        return L10n.text("\(exact). Recorded at \(time). \(note)")
    }

    var body: some View {
        VStack(spacing: 5) {
            TaskMetricLayout {
                HStack(spacing: 5) {
                    HStack(spacing: 5) {
                        Text("Context used").foregroundStyle(.secondary)
                        Text(percent).fontWeight(.medium).monospacedDigit()
                    }
                    .accessibilityElement(children: .combine)
                    Text("Latest record").font(.system(size: 9)).foregroundStyle(.secondary)
                    TaskInfoButton(identifier: "monitor.info.context.\(taskID)",
                        content: TaskInfoContent(title: L10n.text("Context used"), paragraphs: [help]))
                }
                Text(counts).foregroundStyle(.secondary).monospacedDigit()
                    .accessibilityLabel(usage.map {
                        L10n.text("\(TaskTokenText.count($0.used)) / \(TaskTokenText.count($0.window)) tokens")
                    } ?? counts)
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.primary.opacity(0.08))
                    if let usage {
                        Capsule().fill(Color(nsColor: .systemBlue))
                            .frame(width: geometry.size.width * min(1, max(0, usage.percent / 100)))
                    }
                }
                .overlay {
                    if (previewContrast ?? contrast) == .increased {
                        Capsule().strokeBorder(.secondary, lineWidth: 1)
                    }
                }
            }
            .frame(height: 3).accessibilityHidden(true)
        }
        .font(.system(size: 11))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("monitor.context.\(taskID)")
    }
}

private struct StatisticsRequest: Equatable {
    let taskID: String
    let source: TaskAPICostSource?
    let updatedAt: Date
    let tokens: TokenUsage
    let active: Bool
}

/// Mounted only while expanded. A prior task's or prior revision's result is never shown.
struct TaskSessionStatisticsView: View {
    let taskID: String
    let source: TaskAPICostSource?
    let updatedAt: Date
    let tokens: TokenUsage
    let fixture: TaskSessionStatistics?
    var readStatistics: @Sendable (URL, String) async throws -> TaskSessionStatistics = {
        try await TaskSessionStatisticsReader.shared.read(url: $0, threadID: $1)
    }
    @Environment(\.monitorPanelActive) private var panelActive
    @State private var loaded: (request: StatisticsRequest, value: TaskSessionStatistics)?

    private var request: StatisticsRequest {
        StatisticsRequest(taskID: taskID, source: source, updatedAt: updatedAt, tokens: tokens, active: panelActive)
    }
    private var statistics: TaskSessionStatistics? {
        fixture ?? loaded.flatMap { $0.request == request ? $0.value : nil }
    }
    private var explanationStatistics: TaskSessionStatistics? {
        statistics ?? loaded.flatMap {
            $0.request.taskID == taskID && $0.request.source == source ? $0.value : nil
        }
    }
    private var explanationUpdating: Bool { statistics == nil && explanationStatistics != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TaskUsageSectionTitle(title: "Session statistics", symbol: "stopwatch")
            TaskStatisticLine(label: L10n.text("Tool call time (cumulative)"),
                value: TaskSessionText.duration(statistics?.toolMilliseconds),
                infoIdentifier: "monitor.info.tool-time.\(taskID)",
                info: TaskInfoContent(title: L10n.text("Tool call time (cumulative)"),
                    paragraphs: [L10n.text("Completed recorded items only. Parallel tool time is counted once.")],
                    isUpdating: explanationUpdating))
            TaskStatisticLine(label: L10n.text("First token latency (average)"),
                value: TaskSessionText.duration(statistics?.meanTTFTMilliseconds),
                suffix: statistics.map { TaskSessionText.basedOn($0.ttftSampleCount) },
                infoIdentifier: "monitor.info.first-token.\(taskID)",
                info: TaskInfoContent(title: L10n.text("First token latency (average)"),
                    paragraphs: [L10n.text("Average wait from the start of a turn until the model produces its first token. Only successfully completed turns with valid timing records are included."),
                        explanationStatistics.map { TaskSessionText.basedOn($0.ttftSampleCount) } ?? L10n.text("Timing samples unavailable")],
                    isUpdating: explanationUpdating))
            if statistics?.historyUnreadable == true {
                Text("Some timing records are unreadable.").font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("monitor.session-statistics.\(taskID)")
        .task(id: request) {
            let current = request
            guard fixture == nil, current.active, case .codex(let url) = current.source else { return }
            let value: TaskSessionStatistics
            do { value = try await readStatistics(url, current.taskID) }
            catch is CancellationError { return }
            catch { value = TaskSessionStatistics(historyUnreadable: true) }
            guard !Task.isCancelled else { return }
            loaded = (current, value)
        }
    }
}

struct TaskStatisticLine: View {
    let label: String
    let value: String
    var suffix: String?
    let infoIdentifier: String
    let info: TaskInfoContent

    var body: some View {
        TaskMetricLayout {
            HStack(spacing: 3) {
                Text(label).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                TaskInfoButton(identifier: infoIdentifier, content: info)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 4) {
                    Text(value).monospacedDigit()
                    if let suffix { Text("· \(suffix)").font(.system(size: 10)).foregroundStyle(.secondary) }
                }.fixedSize()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(value).monospacedDigit()
                    if let suffix { Text(suffix).font(.system(size: 10)).foregroundStyle(.secondary) }
                }
            }
            .accessibilityElement(children: .combine)
        }
        .font(.system(size: 11))
        .accessibilityElement(children: .contain)
    }
}
