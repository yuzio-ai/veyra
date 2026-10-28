import SwiftUI

/// Presentation choices stay local to the window and never alter reports or export scope.
struct DashboardPresentation {
    var showFilters = false
    var showStatistics = false
    var showLegacyStatistics = false
    var showAllTasks = false
    var metric = DashboardChartMetric.normal
    var distribution = DashboardDistributionDimension.project
    var sort = DashboardTaskSort.recent
    var expandedTaskIDs: Set<String> = []
}

struct DashboardOverview: View {
    let metrics: DashboardMetrics
    let previous: DashboardMetrics?
    @Binding var expanded: Bool
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                metric("Active tasks", String(metrics.activeTasks),
                       context: L10n.text("Active days") + ": \(metrics.activeDays) · " + L10n.text("Subtasks") + ": \(metrics.subtasks)",
                       before: previous.map { Double($0.activeTasks) }, current: Double(metrics.activeTasks))
                metric("Normal endings", String(metrics.normal),
                       context: L10n.text("Open execution") + ": \(metrics.open)",
                       before: previous.map { Double($0.normal) }, current: Double(metrics.normal))
                metric("Median duration", DashboardExport.duration(metrics.median),
                       context: "P90 · " + DashboardExport.duration(metrics.p90),
                       before: previous?.median, current: metrics.median)
                metric("Tokens", DisplayFormat.tokens(metrics.tokens.total),
                       context: metrics.missingTokens > 0
                           ? L10n.text("Missing token usage") + ": \(metrics.missingTokens)"
                           : L10n.text("Cached input") + ": " + DisplayFormat.percent(metrics.cachePercent),
                       before: previous?.tokens.total.map(Double.init), current: metrics.tokens.total.map(Double.init))
            }
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(L10n.text("Failed") + ": \(metrics.failed) · " + L10n.text("Interrupted") + ": \(metrics.interrupted) · "
                         + L10n.text("Unknown result") + ": \(metrics.unknown) · " + L10n.text("Open execution") + ": \(metrics.open)")
                    Text(L10n.text("Input tokens") + ": " + DisplayFormat.tokens(metrics.tokens.input) + " · "
                         + L10n.text("Output tokens") + ": " + DisplayFormat.tokens(metrics.tokens.output) + " · "
                         + L10n.text("Cached input") + ": " + DisplayFormat.percent(metrics.cachePercent))
                    Text("Normal endings describe execution rounds, not completed task goals.")
                }
                .font(.caption).foregroundStyle(.secondary).padding(.top, 10)
                .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            } label: {
                HStack(spacing: 8) {
                    Text("Cumulative duration").foregroundStyle(.secondary)
                    Text(DashboardExport.duration(metrics.elapsed)).monospacedDigit()
                    comparison(before: previous?.elapsed, current: metrics.elapsed)
                    Spacer()
                    Text("More statistics").foregroundStyle(.secondary)
                }.font(.caption)
            }.accessibilityIdentifier("dashboard.moreStatistics")
        }
        .accessibilityElement(children: .contain).accessibilityLabel("Overview")
    }

    private func metric(_ title: LocalizedStringKey, _ value: String, context: String, before: Double?, current: Double?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Text(value).font(.system(size: 26, weight: .semibold)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.75)
            Text(context).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(context)
            comparison(before: before, current: current)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(16)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            if contrast == .increased {
                RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.6))
            }
        }
    }

    @ViewBuilder
    private func comparison(before: Double?, current: Double?) -> some View {
        if let before, before > 0, let current {
            Text(String(format: "%+.1f%%", (current - before) / before * 100))
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
    }
}

struct DashboardFilters: View {
    @Binding var filter: DashboardFilter
    let tasks: [HistoryTask]

    var body: some View {
        HStack(spacing: 14) {
            Picker("Project", selection: $filter.project) {
                Text("All projects").tag(nil as String?)
                ForEach(Array(Set(tasks.compactMap(\.project))).sorted(), id: \.self) { path in
                    Text(URL(fileURLWithPath: path).lastPathComponent).help(path).tag(Optional(path))
                }
            }
            Picker("Model", selection: $filter.model) {
                Text("All models").tag(nil as String?)
                ForEach(Array(Set(tasks.flatMap(\.turns).compactMap(\.model))).sorted(), id: \.self) {
                    Text($0).tag(Optional($0))
                }
            }
            Picker("Source", selection: $filter.source) {
                Text("All sources").tag(nil as String?)
                Text("Desktop").tag(Optional("desktop"))
                Text("CLI").tag(Optional("cli"))
            }.frame(maxWidth: 155)
            Picker("Result", selection: $filter.result) {
                Text("All results").tag(nil as ExecutionResult?)
                ForEach(ExecutionResult.allCases, id: \.self) { Text($0.label).tag(Optional($0)) }
            }
        }.controlSize(.small)
    }
}
