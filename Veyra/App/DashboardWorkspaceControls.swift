import SwiftUI

struct DashboardRangeControls: View {
    @Bindable var store: DashboardStore
    @State private var customDates = false
    var body: some View {
        HStack(spacing: 10) {
            Picker("Period", selection: $store.period) {
                ForEach(DashboardPeriod.allCases, id: \.self) { Text($0.label).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().frame(width: 310)
            if store.page == .analytics { Button("Last 30 days") { store.recentThirtyDays() } }
            if store.period == .custom {
                Button("Edit dates…", systemImage: "calendar") { customDates = true }
                    .accessibilityIdentifier("dashboard.customDates")
                    .popover(isPresented: $customDates) {
                        VStack(spacing: 14) {
                            DatePicker("From", selection: $store.customStart, displayedComponents: .date)
                            DatePicker("Through", selection: $store.customEnd, in: store.customStart..., displayedComponents: .date)
                        }.padding(20).frame(width: 320)
                    }
            }
            Text(store.interval.start.formatted(date: .abbreviated, time: .omitted) + " – "
                 + store.interval.end.addingTimeInterval(-1).formatted(date: .abbreviated, time: .omitted))
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 0)
            Button { store.move(-1) } label: { Image(systemName: "chevron.left") }
                .accessibilityLabel("Previous period").accessibilityIdentifier("dashboard.previous")
            Button("Current period") { store.current() }.accessibilityIdentifier("dashboard.current")
            Button { store.move(1) } label: { Image(systemName: "chevron.right") }
                .accessibilityLabel("Next period").accessibilityIdentifier("dashboard.next")
        }.buttonStyle(DashboardControlButtonStyle()).controlSize(.small)
    }
}

struct DashboardGlobalOverview: View {
    let state: DashboardGlobalState
    @Binding var focus: DashboardFocus
    let historyAvailable: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Global overview").font(.headline)
                Text("All projects · Current state").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 0) {
                Button { focus = .running } label: {
                    DashboardGlobalMetric(title: "Currently running", value: state.runningCount.map(String.init) ?? "—",
                                          note: state.runningCount == nil ? L10n.text("Current status unconfirmed") : L10n.text("Confirmed local process evidence"), color: .accentColor)
                }.accessibilityIdentifier("dashboard.running")
                Divider()
                Button { focus = .attention } label: {
                    DashboardGlobalMetric(title: "Needs attention", value: state.attention.count.formatted(),
                                          note: L10n.text("Last 24 hours"), color: .orange)
                }.accessibilityIdentifier("dashboard.attention")
                Divider()
                Button { focus = .period } label: {
                    DashboardGlobalMetric(title: "Active today", value: historyAvailable ? state.todayCount.formatted() : "—",
                                          note: L10n.text("\(state.todayProjects) projects · Subtasks grouped"), color: .primary)
                }
            }.buttonStyle(.plain).frame(height: 104).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

private struct DashboardGlobalMetric: View {
    let title: LocalizedStringKey
    let value: String
    let note: String
    let color: Color
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.system(size: 28, weight: .semibold)).monospacedDigit().foregroundStyle(color)
                Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
    }
}

struct DashboardAttentionList: View {
    let items: [DashboardAttention]
    let compact: Bool
    let select: (DashboardAttention) -> Void
    let showAll: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Needs attention").font(.headline)
                Text(items.count.formatted()).foregroundStyle(.secondary)
                Text("Last 24 hours").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if !items.isEmpty { Button("View all", action: showAll).buttonStyle(.link) }
            }
            if items.isEmpty {
                Text("No recent records need attention.").font(.caption).foregroundStyle(.secondary)
            } else if compact {
                HStack(spacing: 16) {
                    ForEach(Array(items.prefix(2))) { item in
                        Button { select(item) } label: {
                            Label(item.title, systemImage: item.reasons.contains(.failed) || item.reasons.contains(.interrupted) ? "exclamationmark.circle" : "questionmark.circle")
                                .lineLimit(1)
                        }.buttonStyle(.plain).foregroundStyle(item.reasons.contains(.failed) || item.reasons.contains(.interrupted) ? Color.red : .orange)
                    }
                }.font(.caption)
            } else {
                ForEach(Array(items.prefix(3))) { item in
                    Button { select(item) } label: {
                        HStack(spacing: 12) {
                            RoundedRectangle(cornerRadius: 2).fill(item.reasons.contains(.failed) || item.reasons.contains(.interrupted) ? Color.red : .orange)
                                .frame(width: 4, height: 30)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.title).font(.callout.weight(.medium)).foregroundStyle(.primary).lineLimit(1)
                                Text(item.reasons.map(\.label).joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(item.date, format: .dateTime.hour().minute()).font(.caption).foregroundStyle(.secondary)
                            Text("View records").font(.caption).foregroundStyle(Color.accentColor)
                            Image(systemName: "chevron.right").foregroundStyle(.secondary)
                        }.padding(.vertical, 6).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
        }.accessibilityIdentifier("dashboard.attentionList")
    }
}
