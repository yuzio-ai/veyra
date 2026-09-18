import XCTest
import Foundation

/// Covers the tab-selection state machine: first launch, cross-launch restore,
/// persistence, and the fallback for a stored value that no longer maps.
///
/// `code-01.md` listed all of these as needing a real machine. They do not: the
/// whole state machine is `UserDefaults` plus an initialiser, so a scoped suite
/// verifies it deterministically. Only the visual switching and the keyboard and
/// VoiceOver paths still require the running app.
@MainActor
final class AgentToolSelectionTests: XCTestCase {
    private func scopedDefaults() -> UserDefaults {
        let suite = "veyra-selection-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        return defaults
    }

    private func makeStore(_ defaults: UserDefaults, registry: AgentToolRegistry? = nil) -> MonitorStore {
        MonitorStore(clock: .continuous(), defaults: defaults, registry: registry)
    }

    func testDefaultToolIsCodex() {
        XCTAssertEqual(AgentTool.defaultTool, .codex)
        XCTAssertEqual(AgentTool.allCases.count, 3, "a new tool must be added to the registry, not to allCases only")
    }

    func testFirstLaunchWithoutStoredChoiceSelectsCodex() {
        XCTAssertEqual(makeStore(scopedDefaults()).selectedTool, .codex)
    }

    /// Registry with the named auxiliary sources, so a selection test only ever
    /// lands on a tab that exists (the built-in Codex always leads).
    private static func registry(_ tools: AgentTool...) -> AgentToolRegistry {
        AgentToolRegistry(adapters: tools.map { StubAgentToolAdapter($0) })
    }

    func testStoredChoiceIsRestoredOnRelaunch() {
        let defaults = scopedDefaults()
        defaults.set(AgentTool.qwenWork.rawValue, forKey: MonitorStore.selectedToolKey)
        XCTAssertEqual(makeStore(defaults, registry: Self.registry(.qwenWork)).selectedTool, .qwenWork)
    }

    func testChangingTheSelectionPersistsIt() {
        let defaults = scopedDefaults()
        let store = makeStore(defaults, registry: Self.registry(.workBuddy))
        store.selectedTool = .workBuddy
        XCTAssertEqual(defaults.string(forKey: MonitorStore.selectedToolKey), "workBuddy")
    }

    func testRestoringASelectionDoesNotWriteItBack() {
        // Property observers do not fire during initialisation, so a launch must
        // not rewrite the key. If it did, "no history" would become
        // indistinguishable from "explicitly chose Codex".
        let defaults = scopedDefaults()
        _ = makeStore(defaults)
        XCTAssertNil(defaults.string(forKey: MonitorStore.selectedToolKey))
    }

    func testUnknownStoredValueFallsBackToCodexWithoutRewritingTheKey() {
        let defaults = scopedDefaults()
        defaults.set("doubaoWork", forKey: MonitorStore.selectedToolKey)
        XCTAssertEqual(makeStore(defaults).selectedTool, .codex)
        XCTAssertEqual(defaults.string(forKey: MonitorStore.selectedToolKey), "doubaoWork",
                       "an unmappable value is ignored, not silently rewritten")
    }

    func testReassigningTheSameToolDoesNotRewriteTheKey() {
        let defaults = scopedDefaults()
        defaults.set(AgentTool.workBuddy.rawValue, forKey: MonitorStore.selectedToolKey)
        let store = makeStore(defaults, registry: Self.registry(.workBuddy))
        defaults.removeObject(forKey: MonitorStore.selectedToolKey)
        store.selectedTool = .workBuddy
        XCTAssertNil(defaults.string(forKey: MonitorStore.selectedToolKey),
                     "an unchanged selection is not a change")
    }

    func testAvailableToolsFollowsTheInjectedRegistryRatherThanAllCases() {
        // A store built without a registry gets zero adapters: one tab, and never
        // a tab for a source nobody registered.
        let store = makeStore(scopedDefaults())
        XCTAssertEqual(store.availableTools, [.codex])
        XCTAssertNotEqual(store.availableTools, AgentTool.allCases)
    }

    func testStoredSelectionWithoutATabFallsBackToTheDefaultTool() {
        // `review-01` R2. A stored tool with no tab must not stay selected, or
        // the panel would render a source the segmented control cannot
        // highlight. Unreachable today — all three cases ship in `live()` and no
        // case is retired — so this guards a future source removal. The stored
        // value is left in place rather than erased, matching how an unmappable
        // value is treated: if the source comes back, so does the choice.
        let defaults = scopedDefaults()
        defaults.set(AgentTool.workBuddy.rawValue, forKey: MonitorStore.selectedToolKey)
        let store = makeStore(defaults)
        XCTAssertEqual(store.selectedTool, .codex)
        XCTAssertEqual(store.availableTools, [.codex])
        XCTAssertEqual(defaults.string(forKey: MonitorStore.selectedToolKey), "workBuddy",
                       "a selection with no tab is ignored at launch, not erased")
    }

    func testCodexKeepsItsOwnNoticesWhileEveryOtherSourceUsesTheStatusCard() {
        // `rendersAvailabilityCard` is the switch that keeps the Codex tab
        // byte-for-byte on its pre-tab rendering (AC-4) while a source with no
        // quota surface gets the status card (AC-7).
        let store = makeStore(scopedDefaults())
        let codex = store.presentation(for: .codex)
        XCTAssertFalse(codex.rendersAvailabilityCard)
        XCTAssertEqual(codex.quotaCapability, .supported)

        let workBuddy = store.presentation(for: .workBuddy)
        XCTAssertTrue(workBuddy.rendersAvailabilityCard)
        XCTAssertEqual(workBuddy.quotaCapability, .unsupported)
        XCTAssertNil(workBuddy.quota.snapshot, "a source with no quota source must carry no reading")
        XCTAssertNil(workBuddy.quota.account)
        XCTAssertNil(workBuddy.quota.error)
    }

    func testAnUnreadableSourceShowsItsStatusInsteadOfAnEmptyList() {
        let store = makeStore(scopedDefaults())
        store.applyPreviewTasks([], for: .workBuddy, availability: .unreadable(.schemaUnsupported))
        let presentation = store.presentation(for: .workBuddy)
        XCTAssertTrue(presentation.tasks.isEmpty)
        XCTAssertFalse(presentation.availability.isReady)
        let status = presentation.sourceStatusMessage
        XCTAssertNotNil(status, "an unreadable source must explain itself rather than look empty")
        XCTAssertEqual(presentation.headlineCount, 0)
    }

    func testAReadyButEmptySourceIsDistinguishableFromAnUnreadableOne() {
        let store = makeStore(scopedDefaults())
        store.applyPreviewTasks([], for: .workBuddy, availability: .ready)
        let presentation = store.presentation(for: .workBuddy)
        XCTAssertEqual(presentation.availability, .ready)
        XCTAssertTrue(presentation.tasks.isEmpty)
        XCTAssertNotNil(presentation.sourceStatusMessage, "empty and unreadable must not read the same")
    }

    func testListingSourceCountsEveryTaskAndCarriesItsCaptions() {
        let store = makeStore(scopedDefaults())
        let rows = [AdapterTask(snapshot: Self.snapshot(id: "a", activity: .unknown), caption: "Updated 2026"),
                    AdapterTask(snapshot: Self.snapshot(id: "b", activity: .running), caption: nil)]
        store.applyPreviewTasks(rows, for: .workBuddy)
        let presentation = store.presentation(for: .workBuddy)
        XCTAssertEqual(presentation.tasks.count, 2)
        XCTAssertEqual(presentation.headlineCount, 2, "a listing source counts every task, not only running ones")
        XCTAssertEqual(presentation.captions, ["a": "Updated 2026"])
        XCTAssertNil(presentation.sourceStatusMessage, "a source with rows shows the rows")
    }

    func testSourceDiagnosticsCoversEveryRegisteredTabUsingCountsOnly() async {
        let rows = [AdapterTask(snapshot: Self.snapshot(id: "secret-id", activity: .running),
                                caption: "project-name")]
        let registry = AgentToolRegistry(adapters: [StubAgentToolAdapter(.workBuddy, result: .tasks(rows))])
        let store = makeStore(scopedDefaults(), registry: registry)
        store.applyPreviewTasks(rows, for: .workBuddy)
        let report = await store.sourceDiagnostics()
        // One entry per registered tab, in tab order. `SourceDiagnostic` has no
        // field able to carry a title, project name, branch or URL, so AC-8's
        // privacy claim is structural rather than a formatting rule.
        XCTAssertEqual(report.map(\.tool), [.codex, .workBuddy])
        XCTAssertEqual(report.first(where: { $0.tool == .codex })?.quotaCapability, .supported)
        XCTAssertEqual(report.first(where: { $0.tool == .workBuddy })?.quotaCapability, .unsupported)
        XCTAssertEqual(report.first(where: { $0.tool == .workBuddy })?.taskCount, rows.count)
    }

    func testSourceDiagnosticsIgnoresA_seededSectionForAnUnregisteredTab() async {
        // A seeded section is not a tab. The default registry has no adapters, so
        // diagnostics must report Codex alone even after a section is populated —
        // and it must not open anything to find that out.
        let store = makeStore(scopedDefaults())
        store.applyPreviewTasks([AdapterTask(snapshot: Self.snapshot(id: "x", activity: .unknown),
                                             caption: nil)], for: .workBuddy)
        let report = await store.sourceDiagnostics()
        XCTAssertEqual(report.map(\.tool), [.codex])
        XCTAssertEqual(report.first?.taskCount, 0)
    }

    func testSourceDiagnosticsReportsTheCodexCountItIsGiven() async {
        // `review-01` R1. `--diagnose` reads the Codex records itself and never
        // starts the store, so the row must take that count instead of reading
        // `tasks`, which is structurally empty in that launch context. Without a
        // way to pass it, the field cannot be told apart from "no tasks".
        let store = makeStore(scopedDefaults())
        let report = await store.sourceDiagnostics(codexTaskCount: 3)
        XCTAssertEqual(report.first(where: { $0.tool == .codex })?.taskCount, 3)
    }

    func testSourceDiagnosticsFallsBackToTheLiveCodexTasksWhenNoCountIsPassed() async {
        // A started store's `tasks` is the Codex tab's real source, so omitting
        // the count must keep reporting it.
        let store = makeStore(scopedDefaults())
        store.tasks = [Self.snapshot(id: "a", activity: .running)]
        let report = await store.sourceDiagnostics()
        XCTAssertEqual(report.first(where: { $0.tool == .codex })?.taskCount, 1)
    }

    private static func snapshot(id: String, activity: TaskActivity) -> TaskSnapshot {
        TaskSnapshot(id: id, title: id, model: nil, source: .desktop, parentID: nil, startedAt: nil,
                     updatedAt: Date(timeIntervalSince1970: 1_700_000_000), tokens: TokenUsage(), activity: activity)
    }
}
