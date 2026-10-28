import SwiftUI
import Charts

enum DashboardChartMetric: String, CaseIterable {
    case normal, duration, tokens

    var label: String {
        switch self {
        case .normal: L10n.text("Rounds")
        case .duration: L10n.text("Duration")
        case .tokens: L10n.text("Tokens")
        }
    }

    var title: String {
        switch self {
        case .normal: L10n.text("Normal endings")
        case .duration: L10n.text("Duration (hours)")
        case .tokens: L10n.text("Tokens")
        }
    }

    func value(_ metrics: DashboardMetrics) -> Double? {
        switch self {
        case .normal: Double(metrics.normal)
        case .duration: metrics.elapsed.map { $0 / 3600 }
        case .tokens: metrics.tokens.total.map(Double.init)
        }
    }
}

struct DashboardActivity: View {
    let report: DashboardReport
    let unit: Calendar.Component
    @Binding var metric: DashboardChartMetric
    @Binding var selected: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Trends").font(.headline)
                Image(systemName: "info.circle").font(.caption).foregroundStyle(.secondary)
                    .help("Select a chart date to filter task details. Missing values are omitted from charts.")
                    .accessibilityLabel("Select a chart date to filter task details. Missing values are omitted from charts.")
                Spacer()
                Picker("Trend metric", selection: $metric) {
                    ForEach(DashboardChartMetric.allCases, id: \.self) { Text($0.label).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().frame(width: 220)
                    .accessibilityIdentifier("dashboard.trendMetric")
            }
            DashboardChart(metric: metric, buckets: report.buckets, unit: unit, selected: $selected)
        }
    }
}

private struct DashboardChart: View {
    let metric: DashboardChartMetric
    let buckets: [DashboardBucket]
    let unit: Calendar.Component
    @Binding var selected: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(metric.title).font(.caption).foregroundStyle(.secondary)
            Chart {
                ForEach(buckets) { bucket in
                    if let number = metric.value(bucket.metrics) {
                        BarMark(x: .value("Date", bucket.interval.start, unit: unit), y: .value(metric.title, number), width: .ratio(0.75))
                            .cornerRadius(2)
                            .foregroundStyle(Color.accentColor.opacity(selected == nil || selected == bucket.id ? 0.85 : 0.3))
                            .accessibilityLabel(bucket.interval.start.formatted())
                            .accessibilityValue(number.formatted())
                    }
                }
            }
            .chartXScale(domain: (buckets.first?.interval.start ?? Date())...(buckets.last?.interval.end ?? Date()))
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { axis in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    AxisValueLabel {
                        if let number = axis.as(Double.self) {
                            Text(metric == .tokens ? number.formatted(.number.notation(.compactName))
                                 : number.formatted(.number.precision(.fractionLength(0...1))))
                        }
                    }
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onTapGesture { location in
                            guard let frame = proxy.plotFrame else { return }
                            let x = location.x - geometry[frame].origin.x
                            guard x >= 0, x <= geometry[frame].width else { return }
                            if let date = proxy.value(atX: x, as: Date.self) {
                                selected = buckets.first { $0.interval.start <= date && date < $0.interval.end }?.id
                            }
                        }
                }
            }
            .frame(height: 165)
            Picker("Chart date", selection: $selected) {
                Text("Entire period").tag(nil as Date?)
                ForEach(buckets) { Text($0.id.formatted(date: .abbreviated, time: .shortened)).tag(Optional($0.id)) }
            }
            .controlSize(.small).frame(maxWidth: 280, alignment: .leading)
            .accessibilityLabel(metric.title + " · " + L10n.text("Chart date"))
            .accessibilityIdentifier("dashboard.chartDate")
        }
    }
}

enum DashboardDistributionDimension: String, CaseIterable {
    case project, model, source

    var label: String {
        switch self {
        case .project: L10n.text("Project")
        case .model: L10n.text("Model")
        case .source: L10n.text("Source")
        }
    }

    func values(in report: DashboardReport) -> [DashboardDistribution] {
        switch self {
        case .project: report.projects
        case .model: report.models
        case .source: report.sources
        }
    }
}

struct DashboardDistributions: View {
    let report: DashboardReport
    @Binding var dimension: DashboardDistributionDimension

    var body: some View {
        let values = dimension.values(in: report)
        let total = values.reduce(0.0) { $0 + Double($1.executions) }
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Work distribution").font(.headline)
                Spacer()
                Text("Executions").font(.caption).foregroundStyle(.secondary)
            }
            Picker("Distribution dimension", selection: $dimension) {
                ForEach(DashboardDistributionDimension.allCases, id: \.self) { Text($0.label).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().accessibilityIdentifier("dashboard.distribution")
            ForEach(values) { value in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(dimension == .project && value.id.hasPrefix("/") ? URL(fileURLWithPath: value.id).lastPathComponent : value.id)
                            .lineLimit(1).help(value.id)
                        Spacer(minLength: 8)
                        Text("\(value.executions)").monospacedDigit().foregroundStyle(.secondary)
                    }.font(.callout)
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.05))
                            Capsule().fill(Color.accentColor.opacity(0.75))
                                .frame(width: geometry.size.width * (total > 0 ? Double(value.executions) / total : 0))
                        }
                    }.frame(height: 4).accessibilityHidden(true)
                    Text(DashboardExport.duration(value.elapsed) + " · " + DisplayFormat.tokens(value.tokens) + " token")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            if values.isEmpty {
                Text("No executions match this period and filters.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
