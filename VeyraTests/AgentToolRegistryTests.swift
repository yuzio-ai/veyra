import XCTest
import Foundation

/// Guards the one asymmetry this feature ships with: Codex is served by the
/// store's own long-standing read path and therefore has **no** adapter entry.
///
/// That is a deliberate accepted deviation (`D1` in `code-01.md`), and the point
/// of these tests is to keep it deliberate. `adapter(for:)` returns an optional,
/// so any future code that walks `tools` and unwraps an adapter would skip Codex
/// silently — a failure that surfaces as "Codex stopped refreshing", which is
/// hard to attribute. Pinning the invariant here turns that into a test-time
/// signal instead of a comment nobody reads.
@MainActor
final class AgentToolRegistryTests: XCTestCase {
    private func makeRegistry(_ adapters: [any AgentToolAdapter]) -> AgentToolRegistry {
        AgentToolRegistry(adapters: adapters)
    }

    func testBuiltInToolLeadsTheTabsAndHasNoAdapterEntry() {
        let registry = makeRegistry([StubAgentToolAdapter(.workBuddy), StubAgentToolAdapter(.qwenWork)])
        XCTAssertEqual(registry.tools.first, .codex, "the built-in source always leads")
        XCTAssertNil(registry.adapter(for: .codex), "Codex is served by the store, not by an adapter")
        XCTAssertEqual(registry.auxiliaryTools, [.workBuddy, .qwenWork])
        XCTAssertFalse(registry.auxiliaryTools.contains(.codex))
    }

    func testTabOrderFollowsRegistrationRatherThanAllCases() {
        let registry = makeRegistry([StubAgentToolAdapter(.qwenWork), StubAgentToolAdapter(.workBuddy)])
        XCTAssertEqual(registry.tools, [.codex, .qwenWork, .workBuddy])
        XCTAssertNotEqual(registry.tools, AgentTool.allCases, "tab order must come from the registry")
    }

    func testLiveRegistryExposesCodexThenWorkBuddyThenQwenWork() {
        let registry = AgentToolRegistry.live()
        XCTAssertEqual(registry.tools, [.codex, .workBuddy, .qwenWork])
        XCTAssertEqual(registry.auxiliaryTools, [.workBuddy, .qwenWork])
        XCTAssertNil(registry.adapter(for: .codex))
    }

    func testEmptyRegistryShowsOnlyTheBuiltInSource() {
        // This is the registry every unit test gets, so no test can reach a real
        // user database through a store it constructs.
        let registry = makeRegistry([])
        XCTAssertEqual(registry.tools, [.codex])
        XCTAssertTrue(registry.auxiliaryTools.isEmpty)
        XCTAssertNil(registry.adapter(for: .workBuddy))
        XCTAssertNil(registry.adapter(for: .qwenWork))
    }

    func testRegisteringAnAdapterForTheBuiltInToolIsIgnoredRatherThanHalfApplied() {
        // If someone implements the deferred S5 (`CodexToolAdapter`) and registers
        // it in `live()`, the registry drops it, because the built-in source is
        // served by the store. This test fails the moment that behaviour changes,
        // forcing a conscious decision instead of a silent second serving path.
        let registry = makeRegistry([StubAgentToolAdapter(.codex), StubAgentToolAdapter(.workBuddy)])
        XCTAssertNil(registry.adapter(for: .codex))
        XCTAssertEqual(registry.tools, [.codex, .workBuddy], "the built-in tool must not appear twice")
    }

    func testSecondRegistrationForTheSameToolIsDropped() async {
        let registry = makeRegistry([StubAgentToolAdapter(.workBuddy, availability: .ready),
                                     StubAgentToolAdapter(.workBuddy, availability: .notInstalled)])
        XCTAssertEqual(registry.tools, [.codex, .workBuddy])
        guard let adapter = registry.adapter(for: .workBuddy) else {
            return XCTFail("expected an adapter for the registered auxiliary source")
        }
        let probe = await adapter.probe()
        XCTAssertEqual(probe, .ready, "the first registration wins")
    }

    func testPreviewRegistryPointsEveryAuxiliarySourceAtAnAbsentDatabase() async {
        let registry = AgentToolRegistry.preview()
        XCTAssertEqual(registry.tools, [.codex, .workBuddy, .qwenWork])
        XCTAssertNil(registry.adapter(for: .codex))
        for tool in registry.auxiliaryTools {
            guard let adapter = registry.adapter(for: tool) else {
                return XCTFail("expected an adapter for \(tool.rawValue)")
            }
            let probe = await adapter.probe()
            XCTAssertEqual(probe, .notInstalled, "\(tool.rawValue) must not read a real database in previews")
        }
    }
}
