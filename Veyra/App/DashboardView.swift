import AppKit
import SwiftUI
import UniformTypeIdentifiers
import Combine

struct DashboardView: View {
    @Bindable var store: DashboardStore
    let monitor: MonitorStore?
    @State private var hideTitles = false
    @State private var hideProjects = false
    @State private var showExport = false
    @State private var showClear = false
    @State private var exportError: String?
    @State private var pendingExport: PendingExport?
    @State private var showDataDetails = false
    @State private var showCustomDates = false
    @State private var pendingIndexClear = false
    @State private var presentation: DashboardPresentation

    init(store: DashboardStore, presentation: DashboardPresentation = DashboardPresentation(), monitor: MonitorStore? = nil) {
        self.store = store
        self.monitor = monitor
        _presentation = State(initialValue: presentation)
    }

    private struct PendingExport {
        let report: DashboardReport
        let snapshot: HistorySnapshot
        let csv: Bool
        let hideTitles: Bool
        let hideProjects: Bool
        let period: DashboardPeriod
    }

    var body: some View {
        VStack(spacing: 0) {
            controls.padding(.horizontal, 28).padding(.top, 24).padding(.bottom, 18)
            Divider()
            if store.page == .overview {
                DashboardGlobalOverview(state: store.global, focus: $store.focus,
                                        historyAvailable: store.snapshot.updatedAt != nil && !store.snapshot.historyUnavailable && !store.snapshot.metadataUnavailable)
                    .padding(.horizontal, 28).padding(.top, 16)
                DashboardAttentionList(items: store.global.attention, compact: store.selectedFamilyID != nil,
                                       select: store.selectAttention, showAll: { store.focus = .attention })
                    .padding(.horizontal, 28).padding(.vertical, 12)
            }
            DashboardRangeControls(store: store).padding(.horizontal, 28).padding(.vertical, 10)
            filters.padding(.horizontal, 28).padding(.bottom, 10)
            if store.error != nil || store.snapshot.metadataUnavailable || store.snapshot.historyUnavailable
                || store.snapshot.unreadableFiles > 0 || store.snapshot.malformedEvents > 0 {
                warnings.padding(.horizontal, 28).padding(.bottom, 8)
            }
            if store.page == .analytics {
                ScrollView {
                    DashboardAnalyticsView(store: store, presentation: $presentation)
                        .padding(.horizontal, 28).padding(.vertical, 12)
                }.accessibilityIdentifier("dashboard.content")
            } else {
                if store.focus != .period {
                    HStack {
                        Text(store.focus.label).font(.callout.weight(.medium))
                        Spacer()
                        Button("Clear focus") { store.focus = .period }.buttonStyle(.link)
                    }.padding(.horizontal, 28).padding(.bottom, 8)
                }
                DashboardWorkspaceView(store: store, sort: $presentation.sort)
                    .padding(.horizontal, 28).accessibilityIdentifier("dashboard.content")
            }
            footer.padding(.horizontal, 28).padding(.vertical, 8)
        }
        .frame(minWidth: 850, minHeight: 600)
        .onAppear(perform: updateLive)
        .onChange(of: monitor?.tasksUpdatedAt) { _, _ in updateLive() }
        .onChange(of: monitor?.taskError) { _, _ in updateLive() }
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in updateLive() }
        .onChange(of: store.selectedBucket) { _, date in
            guard let date else { return }
            store.chartInterval = store.report?.buckets.first { $0.id == date }?.interval
        }
        .background(Color(nsColor: .textBackgroundColor))
        .sheet(isPresented: $showExport, onDismiss: presentExport) { exportSheet }
        .sheet(isPresented: $showDataDetails, onDismiss: {
            if pendingIndexClear { pendingIndexClear = false; showClear = true }
        }) { dataDetails }
        .alert("Clear history index?", isPresented: $showClear) {
            Button("Cancel", role: .cancel) { }
            Button("Clear and rebuild", role: .destructive) { Task { await store.clear() } }
        } message: {
            Text("This clears all Veyra history indexes. Available source records will be indexed again. Retained records whose sources were deleted cannot be recovered.")
        }
        .alert("Export failed", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("OK") { exportError = nil }
        } message: { Text(exportError ?? "") }
        .accessibilityIdentifier("dashboard.window")
    }

    private var controls: some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text(store.page == .overview ? "Task overview" : "Analytics").font(.system(size: 24, weight: .semibold))
                Text(store.now, format: .dateTime.year().month().day().weekday()).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Dashboard page", selection: Binding(get: { store.page }, set: store.switchPage)) {
                ForEach(DashboardPage.allCases, id: \.self) { Text($0.label).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().frame(width: 230).accessibilityIdentifier("dashboard.page")
            Spacer()
            Button { store.refresh(); Task { await monitor?.refreshAll() } } label: {
                if store.scanning { ProgressView().controlSize(.small) }
                else { Image(systemName: "arrow.clockwise") }
            }.disabled(store.scanning).help("Refresh").accessibilityLabel("Refresh").accessibilityIdentifier("dashboard.refresh")
            Button("Export…", systemImage: "square.and.arrow.up") { showExport = true }
                .disabled(store.exportContext == nil).accessibilityIdentifier("dashboard.export")
            Menu {
                Button("Index and data details…") { showDataDetails = true }
                Divider()
                Button("Clear index…", role: .destructive) { showClear = true }.disabled(store.scanning)
                    .accessibilityIdentifier("dashboard.clear")
            } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("More actions")
        }.buttonStyle(DashboardControlButtonStyle())
    }

    private func updateLive() {
        guard let monitor else { return }
        store.updateLive(DashboardLiveSnapshot(tasks: monitor.tasks, ancestors: monitor.taskAncestors,
            updatedAt: monitor.tasksUpdatedAt, reliable: monitor.taskError == nil && monitor.taskWarning != .processUnverified,
            homePath: monitor.location.home.path))
    }

    private var periodDescription: String {
        if store.period == .day {
            return store.interval.start.formatted(.dateTime.year().month().day().weekday(.wide))
        }
        return store.interval.start.formatted(date: .abbreviated, time: .omitted) + " – "
            + store.interval.end.addingTimeInterval(-1).formatted(date: .abbreviated, time: .omitted)
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search task titles", text: $store.filter.search).textFieldStyle(.plain)
                        .accessibilityIdentifier("dashboard.search")
                }
                .padding(.horizontal, 10).frame(width: 250, height: 30)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(.primary.opacity(0.15)) }
                Button { presentation.showFilters.toggle() } label: {
                    Label("Filters", systemImage: "line.3.horizontal.decrease")
                    if activeFilterCount > 0 { Text("\(activeFilterCount)").monospacedDigit() }
                }
                .buttonStyle(DashboardControlButtonStyle(selected: presentation.showFilters))
                .accessibilityValue(presentation.showFilters ? L10n.text("Expanded") : L10n.text("Collapsed"))
                .accessibilityIdentifier("dashboard.filters")
                Spacer()
                Text(filterDescription).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .help(filterDescription)
            }
            if presentation.showFilters {
                DashboardFilters(filter: $store.filter, tasks: store.snapshot.tasks)
                    .accessibilityIdentifier("dashboard.filterFields")
            }
        }
    }

    private var activeFilterCount: Int {
        [store.filter.project != nil, store.filter.model != nil, store.filter.source != nil, store.filter.result != nil]
            .filter { $0 }.count
    }

    private var filterDescription: String {
        [store.filter.project.map { URL(fileURLWithPath: $0).lastPathComponent } ?? L10n.text("All projects"),
         store.filter.model ?? L10n.text("All models"), store.filter.source, store.filter.result?.label]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private var warnings: some View {
        VStack(alignment: .leading, spacing: 8) {
            if store.snapshot.metadataUnavailable || store.snapshot.historyUnavailable
                || store.snapshot.unreadableFiles > 0 || store.snapshot.malformedEvents > 0 {
                Label("Some metadata or stored history is unavailable. Statistics may be incomplete.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            if let error = store.error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
        }.font(.callout)
    }

    private func dataNotice(_ report: DashboardReport) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "info.circle").foregroundStyle(.secondary)
            Text(report.previous == nil ? L10n.text("Comparison unavailable: insufficient coverage or missing data.")
                 : L10n.text("Compared with the same elapsed time in the previous period."))
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Data details", systemImage: "chevron.right") { showDataDetails = true }
                .buttonStyle(.plain).foregroundStyle(Color.accentColor)
                .accessibilityIdentifier("dashboard.dataDetails")
        }
        .font(.caption).padding(.vertical, 12)
        .overlay(alignment: .top) { Divider() }.overlay(alignment: .bottom) { Divider() }
    }

    private var footer: some View {
        HStack {
            Text("Local Codex history only")
            Spacer()
            if store.scanning {
                Text(L10n.text("Indexing history…") + " \(store.progress.completed) / \(store.progress.total)")
                    .accessibilityIdentifier("dashboard.progress")
            } else {
                Text(L10n.text("Last indexed") + ": "
                     + (store.snapshot.updatedAt?.formatted(date: .abbreviated, time: .shortened) ?? "—"))
            }
        }.font(.caption).foregroundStyle(.secondary).frame(height: 20)
    }

    private var dataDetails: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Index and data details").font(.title3.bold())
            Text("Local Codex history only. Normal endings describe execution rounds, not completed task goals.")
            if let range = store.snapshot.indexedRange {
                Text(L10n.text("Indexed history") + ": " + range.start.formatted(date: .abbreviated, time: .shortened)
                     + " – " + range.end.formatted(date: .abbreviated, time: .shortened))
            }
            Text(L10n.text("Last indexed") + ": "
                 + (store.snapshot.updatedAt?.formatted(date: .abbreviated, time: .shortened) ?? "—"))
            if let report = store.report {
                Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                    GridRow { Text("Missing duration"); Text("\(report.metrics.missingDuration)").monospacedDigit() }
                    GridRow { Text("Missing token usage"); Text("\(report.metrics.missingTokens)").monospacedDigit() }
                    GridRow { Text("Unreadable records"); Text("\(store.snapshot.unreadableFiles)").monospacedDigit() }
                    GridRow { Text("Malformed events"); Text("\(store.snapshot.malformedEvents)").monospacedDigit() }
                }
            }
            Text("Cumulative duration includes parallel execution and time waiting within rounds. Median and P90 use full durations of rounds ending in this period.")
            Text("Token usage is attributed to its recorded timestamp. Missing values are not zero.")
            warnings
            HStack {
                Button("Clear index…", role: .destructive) { pendingIndexClear = true; showDataDetails = false }
                    .disabled(store.scanning)
                Spacer()
                Button("Done") { showDataDetails = false }.keyboardShortcut(.defaultAction)
            }
        }
        .font(.callout).fixedSize(horizontal: false, vertical: true).padding(24).frame(width: 520)
    }

    private var chartUnit: Calendar.Component { store.period == .day ? .hour : store.period == .year ? .month : .day }

    private var exportSheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Export statistics").font(.headline)
            Text("Export uses the entire selected period and current filters. Chart date selection only filters the on-screen details.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(periodDescription).font(.callout.weight(.medium))
            Toggle("Hide task titles and identifiers", isOn: $hideTitles)
            Toggle("Hide project paths", isOn: $hideProjects)
            HStack {
                Button("Cancel") { showExport = false }
                Spacer()
                Button("Markdown") { export(csv: false) }.disabled(store.exportContext == nil)
                Button("CSV") { export(csv: true) }.disabled(store.exportContext == nil)
            }
        }.padding(24).frame(width: 470)
    }

    private func export(csv: Bool) {
        guard let context = store.exportContext else { return }
        pendingExport = PendingExport(report: context.report, snapshot: context.snapshot, csv: csv,
            hideTitles: hideTitles, hideProjects: hideProjects, period: context.period)
        showExport = false
    }

    private func presentExport() {
        guard let request = pendingExport else { return }
        pendingExport = nil
        let panel = NSSavePanel()
        panel.allowedContentTypes = request.csv ? [.commaSeparatedText] : [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = "Veyra-\(request.period.rawValue)." + (request.csv ? "csv" : "md")
        let save: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            let content = request.csv ? DashboardExport.csv(request.report, hideTitles: request.hideTitles, hideProjects: request.hideProjects)
                : DashboardExport.markdown(request.report, snapshot: request.snapshot, hideTitles: request.hideTitles, hideProjects: request.hideProjects)
            do { try content.write(to: url, atomically: true, encoding: .utf8) }
            catch { exportError = L10n.text("Unable to save the export. Choose a writable location.") }
        }
        // Wait for SwiftUI's options sheet to close before presenting the native save sheet.
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window, completionHandler: save)
        } else {
            panel.begin(completionHandler: save)
        }
    }
}

/// Color-only feedback avoids the system control's press magnification on newer macOS.
struct DashboardControlButtonStyle: ButtonStyle {
    var selected = false
    var segment = false
    var horizontalPadding: CGFloat = 10
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorSchemeContrast) private var contrast

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body)
            .lineLimit(1)
            .padding(.horizontal, horizontalPadding)
            .frame(height: 28)
            .foregroundStyle(Color.primary)
            .background {
                RoundedRectangle(cornerRadius: 5)
                    .fill(selected ? Color(nsColor: .controlBackgroundColor) : Color.primary.opacity(configuration.isPressed ? 0.12 : segment ? 0 : 0.04))
                    .overlay {
                        if selected && configuration.isPressed {
                            RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.08))
                        }
                    }
            }
            .overlay {
                if selected || !segment || contrast == .increased {
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(Color.primary.opacity(contrast == .increased ? 0.6 : 0.12), lineWidth: 1)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 5))
            .opacity(isEnabled ? 1 : 0.45)
    }
}

private struct DashboardPeriodPicker: View {
    @Binding var selection: DashboardPeriod
    @FocusState private var focusedPeriod: DashboardPeriod?

    var body: some View {
        HStack(spacing: 2) {
            ForEach(DashboardPeriod.allCases, id: \.self) { period in
                Button { selection = period } label: {
                    Text(period.label).fixedSize().frame(maxWidth: .infinity)
                }
                .buttonStyle(DashboardControlButtonStyle(selected: selection == period, segment: true, horizontalPadding: 8))
                .focused($focusedPeriod, equals: period)
            }
        }
        .padding(3)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
        .onMoveCommand { direction in
            let periods = DashboardPeriod.allCases
            guard let index = periods.firstIndex(of: selection) else { return }
            let next: Int
            switch direction {
            case .left: next = max(0, index - 1)
            case .right: next = min(periods.count - 1, index + 1)
            default: return
            }
            selection = periods[next]
            focusedPeriod = selection
        }
        // Keep the single-selection picker semantics and VoiceOver actions.
        .accessibilityRepresentation {
            Picker("Period", selection: $selection) {
                ForEach(DashboardPeriod.allCases, id: \.self) { Text($0.label).tag($0) }
            }.pickerStyle(.segmented)
        }
    }
}
