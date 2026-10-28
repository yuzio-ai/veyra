import Foundation

enum DashboardExport {
    static func csv(_ report: DashboardReport, hideTitles: Bool, hideProjects: Bool) -> String {
        let header = ["period_from", "period_before", "task", "parent", "title", "project", "source", "turn", "model", "result", "started_at", "ended_at",
                      "period_elapsed_seconds", "period_input_tokens", "period_output_tokens", "period_cached_input_tokens", "period_total_tokens", "source_available"]
        var lines = [header.joined(separator: ",")]
        for (taskNumber, row) in report.rows.enumerated() {
            for (turnNumber, turn) in row.turns.enumerated() {
                let tokens = DashboardStatistics.tokens(turn, in: report.interval)
                var fields: [String] = [date(report.interval.start), date(report.interval.end), hideTitles ? "task-\(taskNumber + 1)" : row.task.id,
                    hideTitles ? (row.task.parentID == nil ? "" : "subtask") : row.task.parentID ?? "",
                    hideTitles ? "" : row.task.title, hideProjects ? "" : row.task.project ?? "",
                    row.task.source, hideTitles ? "turn-\(turnNumber + 1)" : turn.id, turn.model ?? "", turn.result.rawValue]
                fields += [turn.startedAt.map(date) ?? "", turn.endedAt.map(date) ?? "", turn.elapsed(in: report.interval).map { String(format: "%.3f", $0) } ?? ""]
                fields += [
                    tokens.input.map(String.init) ?? "", tokens.output.map(String.init) ?? "",
                    tokens.cachedInput.map(String.init) ?? "", tokens.total.map(String.init) ?? "",
                    row.task.sourceAvailable && turn.sourceAvailable ? "true" : "false"]
                lines.append(fields.map(csvCell).joined(separator: ","))
            }
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    static func markdown(_ report: DashboardReport, snapshot: HistorySnapshot, hideTitles: Bool, hideProjects: Bool) -> String {
        let m = report.metrics
        let tree = DashboardFamilyTree(tasks: snapshot.tasks)
        let families = tree.families(rows: report.rows, interval: report.interval)
        let usage = DashboardUsage.summarize(report.rows, in: report.interval,
            reliableEmpty: !snapshot.historyUnavailable && !snapshot.metadataUnavailable && snapshot.unreadableFiles == 0)
        var lines = ["# " + L10n.text("Task statistics"), "", "\(date(report.interval.start)) → \(date(report.interval.end))", "",
            L10n.text("Normal endings describe execution rounds, not completed task goals."), "",
            "- \(L10n.text("Active root tasks (unique)")): \(families.count)", "- \(L10n.text("Subtasks")): \(m.subtasks)",
            "- \(L10n.text("Active days")): \(m.activeDays)", "- \(L10n.text("Ended normally")): \(m.normal)",
            "- \(L10n.text("Failed")): \(m.failed)", "- \(L10n.text("Interrupted")): \(m.interrupted)",
            "- \(L10n.text("Unknown result")): \(m.unknown)", "- \(L10n.text("Open execution")): \(m.open)",
            "- \(L10n.text("Cumulative duration (includes parallel execution)")): \(duration(m.elapsed))",
            "- \(L10n.text("Median duration")): \(duration(m.median))", "- P90: \(duration(m.p90))",
            "- \(L10n.text("Recorded Token usage")): \(usage.tokens.map(String.init) ?? "—")",
            "- \(L10n.text("Ended round duration")): \(duration(usage.endedDuration))",
            "- \(L10n.text("Partial usage")): \(usage.missingTokens)",
            "- \(L10n.text("Input tokens")): \(m.tokens.input.map(String.init) ?? "—")",
            "- \(L10n.text("Output tokens")): \(m.tokens.output.map(String.init) ?? "—")",
            "- \(L10n.text("Cached input")): \(DisplayFormat.percent(m.cachePercent))", "",
            "## " + L10n.text("Data coverage"), "",
            "\(date(snapshot.indexedRange?.start)) → \(date(snapshot.indexedRange?.end))",
            "\(L10n.text("Missing duration")): \(m.missingDuration) · \(L10n.text("Missing token usage")): \(m.missingTokens)",
            "\(L10n.text("Unreadable records")): \(snapshot.unreadableFiles) · \(L10n.text("Malformed events")): \(snapshot.malformedEvents)",
            "\(L10n.text("Metadata unavailable")): \(snapshot.metadataUnavailable) · \(L10n.text("History unavailable")): \(snapshot.historyUnavailable)",
            L10n.text("Token usage is attributed to its recorded timestamp. Missing values are not zero."), "",
            "## " + L10n.text("Task details"), "",
            "| \(L10n.text("Task")) | \(L10n.text("Project")) | \(L10n.text("Model")) | \(L10n.text("Source")) | \(L10n.text("Executions")) | \(L10n.text("Result")) | \(L10n.text("Duration")) | Token | \(L10n.text("Source available")) |",
            "| --- | --- | --- | --- | ---: | --- | --- | ---: | --- |"]
        for (index, row) in report.rows.enumerated() {
            let known = DashboardUsage.summarize([row], in: report.interval)
            let title = hideTitles ? "Task \(index + 1)" : row.task.title
            let project = hideProjects ? "—" : row.task.project ?? "—"
            let models = Array(Set(row.turns.compactMap(\.model))).sorted().joined(separator: ", ")
            let results = ExecutionResult.allCases.compactMap { result -> String? in
                let count = DashboardStatistics.resultCount(result, turns: row.turns, in: report.interval)
                return count > 0 ? "\(result.label): \(count)" : nil
            }.joined(separator: "; ")
            var fields = [title, project, models, row.task.source, String(row.turns.count), results.isEmpty ? "—" : results,
                          duration(known.endedDuration), (known.tokens.map(String.init) ?? "—") + (known.incomplete ? " · " + L10n.text("Partial usage") : ""),
                          String(row.task.sourceAvailable && row.turns.allSatisfy(\.sourceAvailable))]
            fields = fields.map(markdownCell)
            lines.append("| " + fields.joined(separator: " | ") + " |")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func duration(_ seconds: TimeInterval?) -> String {
        guard let seconds else { return "—" }
        return DisplayFormat.duration(since: Date(timeIntervalSince1970: 0), now: Date(timeIntervalSince1970: max(0, seconds)))
    }

    private static func date(_ date: Date?) -> String {
        date.map { ISO8601DateFormatter().string(from: $0) } ?? "—"
    }

    private static func csvCell(_ value: String) -> String {
        // Prevent spreadsheet formula evaluation, including whitespace-prefixed cells.
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let safe = trimmed.first.map { "=+-@".contains($0) } == true ? "'" + value : value
        return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func markdownCell(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "|", with: "&#124;")
            .replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
    }
}
