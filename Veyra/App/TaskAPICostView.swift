import SwiftUI

private struct CostRequest: Equatable {
    let source: TaskAPICostSource?
    let tokens: TokenUsage
    let model: String?
    let updatedAt: Date
    let active: Bool
}

/// Mounted only inside an expanded token disclosure. Calculations and history
/// I/O stay off the main actor; a result is shown only for its exact request.
struct TaskAPICostView: View {
    let task: TaskSnapshot
    @Environment(\.monitorPanelActive) private var panelActive
    @State private var loaded: (request: CostRequest, estimate: TaskAPICostEstimate)?

    private var request: CostRequest {
        CostRequest(source: task.apiCostSource, tokens: task.tokens, model: task.model,
                    updatedAt: task.updatedAt, active: panelActive)
    }

    private var estimate: TaskAPICostEstimate? {
        if case .recorded(let value) = task.apiCostSource { return value }
        if task.apiCostSource == nil { return TaskAPICostEstimate(issues: [.missingUsage]) }
        return loaded.flatMap { $0.request == request ? $0.estimate : nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("API reference cost (estimated)").foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(estimate.map { TaskAPICostText.amount($0.total) } ?? L10n.text("Calculating…"))
                    .monospacedDigit().fixedSize()
            }
            .font(.system(size: 11))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("monitor.api-cost.\(task.id)")
            if let estimate {
                if estimate.lines.count > 1 {
                    ForEach(estimate.lines, id: \.model) { line in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(verbatim: line.model).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                            Text(TaskAPICostText.amount(line)).monospacedDigit().fixedSize()
                        }
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .accessibilityElement(children: .combine)
                    }
                }
                if estimate.isPartial {
                    Text("Partial estimate").font(.system(size: 10, weight: .medium))
                }
                ForEach(estimate.issues, id: \.self) { issue in
                    Text(issue.text).font(.system(size: 10)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if estimate.usesLastModel {
                    Text("Based on the last model; historical model changes may affect the estimate.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Text("Converted at official base prices. Not an actual bill or subscription deduction; additional charges excluded.")
                .font(.system(size: 9)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .help(L10n.text("Standard base prices in USD. Prices checked on \(TaskAPICostCatalog.checkedOn)."))
        .task(id: request) {
            let current = request
            guard current.active, case .codex(let url) = current.source else { return }
            let result: TaskAPICostEstimate
            do {
                result = try await TaskAPICostReader.shared.estimate(url: url, expected: current.tokens)
            } catch is CancellationError { return }
            catch { result = TaskAPICostEstimate(issues: [.historyUnreadable]) }
            guard !Task.isCancelled else { return }
            loaded = (current, result)
        }
    }
}
