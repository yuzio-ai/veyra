import Foundation

/// Opportunistic display hints. Never expands the lifecycle/token reader's scan budget.
struct RolloutDisplay: Sendable {
    private struct TurnHints: Sendable {
        var message: String?
        var tool: String?
    }
    private var turns: [String: TurnHints] = [:]
    private var turnOrder: [String] = []

    func progress(for boundary: TurnBoundary?) -> TaskProgress? {
        guard let boundary, boundary.isRunning, let id = boundary.turnID, let hints = turns[id] else { return nil }
        if let text = hints.message { return TaskProgress(kind: .message, text: text) }
        return hints.tool.map { TaskProgress(kind: .tool, text: $0) }
    }

    mutating func apply(_ event: JSONValue, newestFirst: Bool) {
        let payload = event["payload"]
        if event["type"].string == "event_msg", payload["type"].string == "task_started", !newestFirst {
            // A new turn must not inherit display hints from the previous turn.
            let id = payload["turn_id"].string
            turns = turns.filter { $0.key == id }; turnOrder = turnOrder.filter { $0 == id }
        }
        guard event["type"].string == "response_item",
              let turnID = TaskText.nonempty(payload["internal_chat_message_metadata_passthrough"]["turn_id"].string
                ?? payload["turn_id"].string) else { return }
        let kind = payload["type"].string
        let message: String?, tool: String?
        if kind == "message", payload["role"].string == "assistant", payload["phase"].string == "commentary" {
            // Read only explicitly public text, never reasoning, agent assignments or encrypted blocks.
            let blocks = payload["content"].array ?? []
            guard !blocks.contains(where: { $0["type"].string == "encrypted_content" }) else { return }
            let texts = blocks.filter { $0["type"].string == "output_text" }.compactMap { $0["text"].string }
            guard !texts.contains(where: { $0.contains("gAAAAA") }),
                  let text = TaskText.nonempty(texts.joined(separator: "\n")) else { return }
            // Plain text only; bound retained transcript-derived data, including the hover summary.
            message = String(text.prefix(2_000)); tool = nil
        } else if kind == "function_call" || kind == "custom_tool_call" {
            guard let name = TaskText.nonempty(payload["name"].string), name.count <= 120,
                  name.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.:-").contains($0) }) else { return }
            message = nil; tool = Self.toolLabel(name)
        } else { return }

        if turns[turnID] == nil {
            // Reverse reads keep the newest eight turns; forward reads evict the oldest.
            if newestFirst && turns.count >= 8 { return }
            if newestFirst { turnOrder.insert(turnID, at: 0) } else { turnOrder.append(turnID) }
            if turnOrder.count > 8 { turns.removeValue(forKey: turnOrder.removeFirst()) }
        }
        var hints = turns[turnID] ?? TurnHints()
        if let message, !newestFirst || hints.message == nil { hints.message = message }
        if let tool, !newestFirst || hints.tool == nil { hints.tool = tool }
        turns[turnID] = hints
    }

    private static func toolLabel(_ name: String) -> String {
        let leaf = name.split(separator: ".").last.map(String.init) ?? name
        switch leaf {
        case "exec": return "执行工具脚本"
        case "exec_command", "shell", "shell_command": return "执行命令"
        case "apply_patch": return "修改文件"
        case "view_image": return "查看图片"
        case "read_file": return "读取文件"
        case "query_docs": return "查阅文档"
        case "spawn_agent", "followup_task": return "分派子任务"
        case "send_message", "send_message_to_thread": return "发送协作消息"
        case "wait", "wait_agent", "sleep", "write_stdin": return "等待或读取执行结果"
        default: return "调用工具：\(name)"
        }
    }
}
