import SwiftUI

private struct CostRequest: Equatable {
    let taskID: String
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
    var readEstimate: @Sendable (URL, TokenUsage) async throws -> TaskAPICostEstimate = {
        try await TaskAPICostReader.shared.estimate(url: $0, expected: $1)
    }
    @Environment(\.monitorPanelActive) private var panelActive
    @State private var loaded: (request: CostRequest, estimate: TaskAPICostEstimate)?

    private var request: CostRequest {
        CostRequest(taskID: task.id, source: task.apiCostSource, tokens: task.tokens, model: task.model,
                    updatedAt: task.updatedAt, active: panelActive)
    }

    private var estimate: TaskAPICostEstimate? {
        if case .recorded(let value) = task.apiCostSource { return value }
        if task.apiCostSource == nil { return TaskAPICostEstimate(issues: [.missingUsage]) }
        return loaded.flatMap { $0.request == request ? $0.estimate : nil }
    }

    private var status: String? {
        guard let estimate else { return nil }
        if estimate.total == nil { return L10n.text("Estimate unavailable") }
        return estimate.isPartial ? L10n.text("Partial estimate") : nil
    }

    private var explanation: TaskInfoContent {
        // Only the explanation may retain an older revision, explicitly marked
        // as updating. The card's estimate above always matches the exact request.
        let previous = loaded.flatMap {
            $0.request.taskID == task.id && $0.request.source == task.apiCostSource ? $0.estimate : nil
        }
        let displayed = estimate ?? previous
        var paragraphs = [L10n.text("Converted at official base prices. Not an actual bill or subscription deduction; additional charges excluded."),
                          L10n.text("Standard base prices in USD. Prices checked on \(TaskAPICostCatalog.checkedOn).")]
        var details: [TaskInfoDetail] = []
        if let estimate = displayed {
            paragraphs += estimate.issues.map(\.text)
            if estimate.usesLastModel {
                paragraphs.append(L10n.text("Based on the last model; historical model changes may affect the estimate."))
            }
            details.append(TaskInfoDetail(label: L10n.text("Total"), value: TaskAPICostText.amount(estimate.total)))
            details += estimate.lines.map { TaskInfoDetail(label: $0.model, value: TaskAPICostText.amount($0)) }
        } else {
            paragraphs.append(L10n.text("Calculating…"))
        }
        return TaskInfoContent(title: L10n.text("API cost (reference)"), paragraphs: paragraphs, details: details,
                               isUpdating: estimate == nil && previous != nil)
    }

    var body: some View {
        TaskStatisticLine(label: L10n.text("API cost (reference)"),
            value: estimate.map { TaskAPICostText.amount($0.total) } ?? L10n.text("Calculating…"),
            suffix: status, infoIdentifier: "monitor.info.api-cost.\(task.id)", info: explanation)
        .accessibilityIdentifier("monitor.api-cost.\(task.id)")
        .task(id: request) {
            let current = request
            guard current.active, case .codex(let url) = current.source else { return }
            let result: TaskAPICostEstimate
            do {
                result = try await readEstimate(url, current.tokens)
            } catch is CancellationError { return }
            catch { result = TaskAPICostEstimate(issues: [.historyUnreadable]) }
            guard !Task.isCancelled else { return }
            loaded = (current, result)
        }
    }
}
