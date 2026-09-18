import Foundation

/// Shared test double for `AgentToolAdapter`.
///
/// `availability` and `result` are both caller-chosen so a test can distinguish
/// two registrations of the same tool, and can exercise the ready / empty /
/// unreadable paths without touching a real user database.
struct StubAgentToolAdapter: AgentToolAdapter, Sendable {
    let tool: AgentTool
    let availability: AgentToolAvailability
    let result: AdapterTaskResult

    init(_ tool: AgentTool,
         availability: AgentToolAvailability = .ready,
         result: AdapterTaskResult = .empty) {
        self.tool = tool
        self.availability = availability
        self.result = result
    }

    var quotaCapability: QuotaCapability { .unsupported }
    func probe() async -> AgentToolAvailability { availability }
    func readTasks() async -> AdapterTaskResult { result }
}
