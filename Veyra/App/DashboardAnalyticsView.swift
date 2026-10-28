import SwiftUI
import Charts

struct DashboardAnalyticsView: View {
    @Bindable var store: DashboardStore
    @Binding var presentation: DashboardPresentation
    @State private var tokenHeatmap = true
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 24) {
                DashboardValue(title: "Active root tasks (unique)", value: store.analytics.taskCount.formatted())
                Divider()
                DashboardValue(title: "Recorded Token usage", value: DisplayFormat.tokens(store.analytics.usage.tokens))
                Divider()
                DashboardValue(title: "Active days", value: store.analytics.activeDays.formatted())
            }.frame(height: 64).padding(12).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
            if store.analytics.usage.missingTokens > 0 {
                Text("Usage incomplete: \(store.analytics.usage.missingTokens) rounds").font(.caption).foregroundStyle(.orange)
            } else if store.analytics.usage.sourceIncomplete {
                Text("Some source records are unavailable; totals are partial.").font(.caption).foregroundStyle(.orange)
            }
            DashboardCombinationChart(buckets: store.analytics.buckets, weekly: $store.weekly, selected: $store.chartInterval)
            DashboardHeatmap(analytics: store.analytics, tokenMetric: $tokenHeatmap, selected: $store.chartInterval)
            if let selected = store.chartInterval {
                HStack {
                    Text(selected.start, format: .dateTime.year().month().day()).font(.headline)
                    Text("Selected date details").foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear date selection") { store.chartInterval = nil }.buttonStyle(.link)
                }
            }
            DashboardWorkspaceView(store: store, sort: $presentation.sort).frame(height: 540)
            DisclosureGroup("More statistics", isExpanded: $presentation.showStatistics) {
                if let report = store.report {
                    DashboardOverview(metrics: report.metrics, previous: report.previous, expanded: $presentation.showLegacyStatistics)
                    HStack(alignment: .top, spacing: 24) {
                        DashboardActivity(report: report, unit: store.period == .day ? .hour : store.period == .year ? .month : .day,
                                          metric: $presentation.metric, selected: $store.selectedBucket)
                        DashboardDistributions(report: report, dimension: $presentation.distribution).frame(width: 240)
                    }
                }
            }.accessibilityIdentifier("dashboard.advancedStatistics")
        }
    }
}

private struct DashboardCombinationChart: View {
    let buckets: [DashboardDailyBucket]
    @Binding var weekly: Bool
    @Binding var selected: DateInterval?
    @State private var hovered: Date?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Text("Tasks and Token trend").font(.headline)
                Label("Task count", systemImage: "square.fill").foregroundStyle(.secondary)
                Label("Token usage", systemImage: "line.diagonal").foregroundStyle(Color.accentColor)
                Spacer()
                Picker("Chart grouping", selection: $weekly) {
                    Text("Daily").tag(false)
                    Text("Weekly").tag(true)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 145)
            }.font(.caption)
            HStack {
                Text("Task count").foregroundStyle(.secondary)
                Spacer()
                Text("Token").foregroundStyle(Color.accentColor)
            }.font(.caption)
            Chart {
                ForEach(buckets) { bucket in
                    RectangleMark(xStart: .value("From", bucket.interval.start.addingTimeInterval(bucket.interval.duration * 0.15)),
                            xEnd: .value("Through", bucket.interval.end.addingTimeInterval(-bucket.interval.duration * 0.15)),
                            yStart: .value("Baseline", 0.0), yEnd: .value("Task count", Double(bucket.tasks) / taskMaximum))
                        .foregroundStyle(Color.secondary.opacity(0.24))
                        .accessibilityLabel(bucket.id.formatted(date: .abbreviated, time: .omitted))
                        .accessibilityValue(description(bucket))
                    if let tokens = bucket.usage.tokens, bucket.covered {
                        LineMark(x: .value("Date", midpoint(bucket.interval)), y: .value("Token", Double(tokens) / tokenMaximum),
                                 series: .value("Coverage segment", bucket.segment))
                            .foregroundStyle(Color.accentColor).interpolationMethod(.linear)
                        if bucket.usage.incomplete {
                            PointMark(x: .value("Date", midpoint(bucket.interval)), y: .value("Token", Double(tokens) / tokenMaximum))
                                .symbol(.diamond).foregroundStyle(Color.orange)
                        }
                    }
                }
                if let bucket = highlighted {
                    RuleMark(x: .value("Date", midpoint(bucket.interval))).foregroundStyle(Color.secondary.opacity(0.35))
                        .annotation(position: .top, alignment: .leading, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(bucket.id, format: .dateTime.month().day()).fontWeight(.medium)
                                Text(description(bucket))
                            }.font(.caption).padding(8).background(.background, in: RoundedRectangle(cornerRadius: 6))
                        }
                }
            }
            .chartYScale(domain: 0...1)
            .chartXScale(domain: (buckets.first?.interval.start ?? Date())...(buckets.last?.interval.end ?? Date()))
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 6)) }
            .chartYAxis {
                AxisMarks(position: .leading, values: [0.0, 0.25, 0.5, 0.75, 1.0]) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.4))
                    AxisValueLabel { if let value = value.as(Double.self) { Text((value * taskMaximum).formatted(.number.precision(.fractionLength(0)))) } }
                }
                AxisMarks(position: .trailing, values: [0.0, 0.25, 0.5, 0.75, 1.0]) { value in
                    AxisValueLabel { if let value = value.as(Double.self) {
                        Text((value * tokenMaximum).formatted(.number.notation(.compactName).precision(.fractionLength(0...1))))
                            .foregroundStyle(Color.accentColor)
                    } }
                }
            }
            .chartXSelection(value: $hovered)
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            if case .active(let location) = phase, let frame = proxy.plotFrame {
                                hovered = proxy.value(atX: location.x - geometry[frame].origin.x, as: Date.self)
                            } else { hovered = nil }
                        }
                        .onTapGesture { location in
                            guard let frame = proxy.plotFrame,
                                  let date = proxy.value(atX: location.x - geometry[frame].origin.x, as: Date.self) else { return }
                            selected = buckets.first { $0.interval.start <= date && date < $0.interval.end }?.interval
                        }
                }
            }
            .frame(height: 165)
            Picker("Chart date", selection: Binding(get: { selected?.start }, set: { date in selected = buckets.first { $0.id == date }?.interval })) {
                Text("Entire period").tag(nil as Date?)
                ForEach(buckets) { Text($0.id.formatted(date: .abbreviated, time: .omitted)).tag(Optional($0.id)) }
            }.frame(maxWidth: 310).controlSize(.small).accessibilityIdentifier("dashboard.chartDate")
            Text("Gray bars: unique root tasks. Blue line: recorded Token. Gaps indicate missing usage; diamonds indicate partial usage.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(16).background(Color.primary.opacity(0.018), in: RoundedRectangle(cornerRadius: 8))
    }
    private var taskMaximum: Double { max(4, ceil(Double(buckets.map(\.tasks).max() ?? 0) / 4) * 4) }
    private var tokenMaximum: Double { DashboardAnalytics.axisMaximum(Double(buckets.compactMap { $0.usage.tokens }.max() ?? 0)) }
    private var highlighted: DashboardDailyBucket? {
        if let hovered { return buckets.first { $0.interval.start <= hovered && hovered < $0.interval.end } }
        return buckets.first { $0.interval == selected }
    }
    private func midpoint(_ interval: DateInterval) -> Date { interval.start.addingTimeInterval(interval.duration / 2) }
    private func description(_ bucket: DashboardDailyBucket) -> String {
        let coverage = !bucket.covered ? L10n.text("Uncovered date") : bucket.usage.tokens == nil
            ? L10n.text("Missing token usage") : bucket.usage.incomplete ? L10n.text("Partial usage") : ""
        return L10n.text("\(bucket.tasks) tasks") + " · " + DisplayFormat.tokens(bucket.usage.tokens) + " Token"
            + (coverage.isEmpty ? "" : " · " + coverage)
    }
}

private struct DashboardHeatmap: View {
    let analytics: DashboardAnalytics
    @Binding var tokenMetric: Bool
    @Binding var selected: DateInterval?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Daily activity").font(.headline)
                Spacer()
                if let range = analytics.annualInterval {
                    Text(range.start.formatted(date: .abbreviated, time: .omitted) + " – " + range.end.addingTimeInterval(-1).formatted(date: .abbreviated, time: .omitted))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Picker("Heatmap metric", selection: $tokenMetric) {
                    Text("Task count").tag(false)
                    Text("Token usage").tag(true)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 220)
            }
            GeometryReader { geometry in
                let columns = analytics.cells.count / 7
                let size = max(6, min(16, (geometry.size.width - 24) / CGFloat(max(1, columns)) - 3))
                HStack(alignment: .top, spacing: 5) {
                    VStack(spacing: 3) {
                        ForEach(0..<7, id: \.self) { day in
                            Text(day == 0 ? L10n.text("Mon") : day == 2 ? L10n.text("Wed") : day == 4 ? L10n.text("Fri") : "")
                                .font(.system(size: 9)).frame(width: 20, height: size)
                        }
                    }.padding(.top, 22)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 3) {
                            ForEach(0..<columns, id: \.self) { column in
                                let cell = analytics.cells[column * 7]
                                let show = column == 0 ? Calendar.current.component(.day, from: cell.date) <= 14
                                    : Calendar.current.component(.month, from: cell.date) != Calendar.current.component(.month, from: analytics.cells[(column - 1) * 7].date)
                                Text(show ? cell.date.formatted(.dateTime.month(.abbreviated)) : "")
                                    .font(.system(size: 10)).fixedSize().frame(width: size, height: 16, alignment: .leading)
                            }
                        }
                        LazyHGrid(rows: Array(repeating: GridItem(.fixed(size), spacing: 3), count: 7), spacing: 3) {
                            ForEach(analytics.cells) { cell in
                                DashboardHeatmapCell(cell: cell, value: metric(cell), thresholds: thresholds,
                                                     tokenMetric: tokenMetric, selected: selected?.start == cell.date,
                                                     select: { selected = cell.bucket?.interval })
                                    .frame(width: size, height: size)
                            }
                        }
                    }
                }
            }.frame(height: 155)
            HStack(spacing: 10) {
                Text("Less").font(.caption)
                ForEach(thresholds, id: \.self) { threshold in
                    HStack(spacing: 3) {
                        RoundedRectangle(cornerRadius: 2).fill(Color.accentColor.opacity(intensity(threshold))).frame(width: 12, height: 12)
                        Text("≤" + (tokenMetric ? DisplayFormat.tokens(threshold) : threshold.formatted())).font(.caption2)
                    }
                }
                Text("More").font(.caption)
                Spacer()
                Label("No activity", systemImage: "square").font(.caption)
                Label("Missing token usage", systemImage: "line.diagonal").font(.caption)
                Label("Uncovered date", systemImage: "square.dashed").font(.caption)
            }.foregroundStyle(.secondary)
            Picker("Activity date", selection: Binding(get: { selected?.start }, set: { date in selected = analytics.cells.first { $0.id == date }?.bucket?.interval })) {
                Text("Entire period").tag(nil as Date?)
                ForEach(analytics.cells.filter { $0.bucket != nil }) { Text($0.date.formatted(date: .abbreviated, time: .omitted)).tag(Optional($0.date)) }
            }.controlSize(.small).frame(maxWidth: 310).accessibilityIdentifier("dashboard.heatmapDate")
        }.padding(16).background(Color.primary.opacity(0.018), in: RoundedRectangle(cornerRadius: 8))
    }
    private func metric(_ cell: DashboardCalendarCell) -> Int64? { tokenMetric ? cell.bucket?.usage.tokens : cell.bucket.map { Int64($0.tasks) } }
    private var thresholds: [Int64] { DashboardAnalytics.thresholds(analytics.cells.compactMap(metric)) }
    private func intensity(_ value: Int64) -> Double {
        guard let index = thresholds.firstIndex(where: { value <= $0 }) else { return 0.9 }
        return 0.18 + Double(index + 1) / Double(max(1, thresholds.count)) * 0.72
    }
}

private struct DashboardHeatmapCell: View {
    let cell: DashboardCalendarCell
    let value: Int64?
    let thresholds: [Int64]
    let tokenMetric: Bool
    let selected: Bool
    let select: () -> Void
    var body: some View {
        Button(action: select) {
            ZStack {
                RoundedRectangle(cornerRadius: 2).fill(fill)
                if let bucket = cell.bucket, bucket.covered && tokenMetric && (bucket.usage.incomplete || value == nil) {
                    Path { path in
                        for offset in stride(from: -20.0, through: 20.0, by: 5) {
                            path.move(to: CGPoint(x: offset, y: 0)); path.addLine(to: CGPoint(x: offset + 20, y: 20))
                        }
                    }.stroke(Color.secondary.opacity(0.5), lineWidth: 0.6).clipped()
                }
                if let bucket = cell.bucket, !bucket.covered {
                    RoundedRectangle(cornerRadius: 2).strokeBorder(Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 0.7, dash: [2, 2]))
                }
                if selected { RoundedRectangle(cornerRadius: 2).strokeBorder(Color.primary, lineWidth: 2) }
            }.contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(cell.bucket == nil)
            .help(description).accessibilityLabel(description)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
    private var fill: Color {
        guard let bucket = cell.bucket else { return .clear }
        guard bucket.covered else { return Color.secondary.opacity(0.045) }
        guard let value else { return Color.orange.opacity(0.10) }
        guard value > 0 else { return Color.primary.opacity(0.025) }
        let index = thresholds.firstIndex(where: { value <= $0 }) ?? max(0, thresholds.count - 1)
        return Color.accentColor.opacity(0.18 + Double(index + 1) / Double(max(1, thresholds.count)) * 0.72)
    }
    private var description: String {
        guard let bucket = cell.bucket else { return cell.date.formatted() }
        return cell.date.formatted(date: .abbreviated, time: .omitted) + " · " + L10n.text("\(bucket.tasks) tasks") + " · "
            + DisplayFormat.tokens(bucket.usage.tokens) + " Token"
            + (!bucket.covered ? " · " + L10n.text("Uncovered date") : bucket.usage.incomplete ? " · " + L10n.text("Partial usage") : "")
    }
}
