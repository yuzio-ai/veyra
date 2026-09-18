import Foundation

/// The single extension point for monitored sources.
///
/// Registering one more adapter is what "adding a source" means: the tab bar,
/// the panel layout, `PanelSizing` and the Codex state machine stay untouched.
@MainActor
final class AgentToolRegistry {
    private let adapters: [AgentTool: any AgentToolAdapter]

    /// Tab display order. The built-in resident (Codex) always leads; auxiliary
    /// sources follow in registration order. Deliberately not `allCases` order,
    /// so reordering tabs is a registry edit.
    let tools: [AgentTool]

    init(adapters: [any AgentToolAdapter], builtIn: AgentTool = .codex) {
        var map: [AgentTool: any AgentToolAdapter] = [:]
        var order: [AgentTool] = [builtIn]
        for adapter in adapters where adapter.tool != builtIn && map[adapter.tool] == nil {
            map[adapter.tool] = adapter
            order.append(adapter.tool)
        }
        self.adapters = map
        self.tools = order
    }

    /// The adapters the running application uses. Tests construct the store
    /// without this, so no unit test reads a real user database.
    static func live() -> AgentToolRegistry {
        AgentToolRegistry(adapters: [WorkBuddyToolAdapter(), QwenWorkToolAdapter()])
    }

    /// Fixture registry for layout previews. Every adapter points at a path that
    /// cannot exist, so even a stray read reports "not detected" instead of
    /// touching a real user database — preview scenarios seed their sections
    /// from fixtures instead of reading anything.
    static func preview() -> AgentToolRegistry {
        let unavailable = URL(fileURLWithPath: "/nonexistent/veyra-preview/unavailable.db")
        return AgentToolRegistry(adapters: [WorkBuddyToolAdapter(databaseURL: unavailable),
                                            QwenWorkToolAdapter(databaseURL: unavailable)])
    }

    func adapter(for tool: AgentTool) -> (any AgentToolAdapter)? { adapters[tool] }

    /// Auxiliary sources, in display order. Codex is served by the store's own
    /// long-standing read path and has no adapter entry.
    var auxiliaryTools: [AgentTool] { tools.filter { adapters[$0] != nil } }
}
