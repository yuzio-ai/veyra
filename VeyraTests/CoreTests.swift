import XCTest
import Foundation
import SQLite3

final class CoreTests: XCTestCase {
    private func json(_ text: String) throws -> JSONValue { try JSONValue.decode(Data(text.utf8)) }
    private func temp() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testMultiBucketPrecedenceDynamicWindowsAndClamping() throws {
        let result = QuotaSnapshot.parse(try json(#"{"rateLimits":{"primary":{"usedPercent":99}},"rateLimitsByLimitId":{"spark":{"limitName":"Spark","primary":{"usedPercent":-5,"windowDurationMins":300},"secondary":{"usedPercent":150,"windowDurationMins":10080}},"codex":{"primary":{"usedPercent":48,"windowDurationMins":10080,"resetsAt":1788878214},"secondary":null}}}"#))
        XCTAssertEqual(result.windows.count, 3)
        XCTAssertEqual(result.menuWindow?.bucketID, "codex")
        XCTAssertEqual(result.menuWindow?.durationLabel, L10n.text("Week"))
        XCTAssertEqual(result.menuWindow?.remainingPercent, 52)
        XCTAssertEqual(result.menuWindow?.resetsAt?.timeIntervalSince1970, 1788878214)
        XCTAssertEqual(result.windows[1].remainingPercent, 100)
        XCTAssertEqual(result.windows[1].durationLabel, "5h")
        XCTAssertEqual(result.windows[2].remainingPercent, 0)
    }

    func testLegacyQuotaMissingValuesAndAuthoritativeEmptyMap() throws {
        let result = QuotaSnapshot.parse(try json(#"{"rateLimits":{"primary":{"usedPercent":null,"windowDurationMins":15,"resetsAt":null},"secondary":null}}"#))
        XCTAssertEqual(result.windows.count, 1)
        XCTAssertNil(result.menuWindow?.remainingPercent)
        XCTAssertNil(result.menuWindow?.resetsAt)
        XCTAssertEqual(result.menuWindow?.durationLabel, L10n.text("\(Int64(15))min"))
        XCTAssertEqual(DisplayFormat.percent(result.menuWindow?.remainingPercent), "—")
        let empty = QuotaSnapshot.parse(try json(#"{"rateLimits":{"primary":{"usedPercent":0}},"rateLimitsByLimitId":{}}"#))
        XCTAssertTrue(empty.windows.isEmpty)
    }

    func testResetDoesNotInventFullQuota() throws {
        let snapshot = QuotaSnapshot.parse(try json(#"{"rateLimits":{"primary":{"usedPercent":100,"resetsAt":1}}}"#))
        XCTAssertEqual(snapshot.menuWindow?.remainingPercent, 0)
        XCTAssertEqual(DisplayFormat.percent(0.2), "<1%")
    }

    func testQuotaCachePreservesNetworkFailureButInvalidatesAccountChange() throws {
        let first = AccountSnapshot(json: try json(#"{"type":"chatgpt","email":"one@example.invalid"}"#))
        let second = AccountSnapshot(json: try json(#"{"type":"chatgpt","email":"two@example.invalid"}"#))
        let snapshot = QuotaSnapshot.parse(try json(#"{"rateLimits":{"primary":{"usedPercent":30}}}"#))
        var state = QuotaDisplayState()
        state.apply(QuotaRefresh(account: first, snapshot: snapshot))
        state.apply(QuotaRefresh(account: first, error: .rpcFailed))
        XCTAssertEqual(state.snapshot, snapshot)
        state.apply(QuotaRefresh(account: second, error: .rpcFailed))
        XCTAssertNil(state.snapshot)
        state.apply(QuotaRefresh(account: second, snapshot: snapshot))
        state.apply(QuotaRefresh(error: .notLoggedIn, invalidatePrevious: true))
        XCTAssertNil(state.snapshot)
        XCTAssertNil(state.account)
    }

    func testTokenBreakdownsAreSubsetsNotAdditionalUsage() throws {
        let usage = TokenUsage(json: try json(#"{"input_tokens":100,"cached_input_tokens":80,"output_tokens":20,"reasoning_output_tokens":15,"total_tokens":120}"#))
        XCTAssertEqual(usage.total, 120)
        XCTAssertEqual(usage.cachedInput, 80)
        let derived = TokenUsage(json: try json(#"{"input_tokens":100,"cached_input_tokens":80,"output_tokens":20,"reasoning_output_tokens":15}"#))
        XCTAssertEqual(derived.total, 120)
        let missing = TokenUsage(json: try json(#"{"input_tokens":100,"output_tokens":null}"#))
        XCTAssertNil(missing.total)
        XCTAssertNil(missing.output)
        XCTAssertEqual(DisplayFormat.tokens(nil), "—")
    }

    func testCachedInputPercentUsesRawInputCount() throws {
        let usage = TokenUsage(input: 877_208, output: 6_892, cachedInput: 698_400, total: 884_100)
        XCTAssertEqual(try XCTUnwrap(usage.cachedInputPercent), 79.616236970023, accuracy: 0.000001)
        XCTAssertEqual(TokenUsage(input: 100, cachedInput: 0).cachedInputPercent, 0)
        XCTAssertEqual(TokenUsage(input: 100, cachedInput: 100).cachedInputPercent, 100)
        XCTAssertEqual(TokenUsage(input: Int64.max, cachedInput: Int64.max).cachedInputPercent, 100)
    }

    func testCachedInputPercentUnavailableForMissingOrInvalidCounts() {
        let usages = [
            TokenUsage(),
            TokenUsage(input: 100),
            TokenUsage(cachedInput: 80),
            TokenUsage(input: 0, cachedInput: 0),
            TokenUsage(input: 0, cachedInput: 10),
            TokenUsage(input: 100, cachedInput: 101),
            TokenUsage(input: -1, cachedInput: 0),
            TokenUsage(input: 100, cachedInput: -1)
        ]
        for usage in usages {
            XCTAssertNil(usage.cachedInputPercent, "Unexpected percentage for \(usage)")
        }
    }

    private var start: String {
        #"{"timestamp":"2026-09-03T01:00:00Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-1"}}"# + "\n"
    }
    private func token(_ amount: Int) -> String {
        #"{"timestamp":"2026-09-03T01:01:00.123Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"output_tokens":20,"total_tokens":\#(amount)}}}}"# + "\n"
    }
    private var complete: String {
        #"{"timestamp":"2026-09-03T01:02:00Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-1"}}"# + "\n"
    }
    private func append(_ text: String, to url: URL) throws {
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        try file.seekToEnd(); try file.write(contentsOf: Data(text.utf8))
    }

    func testIncrementalRolloutDoesNotSumSnapshotsAndBuffersPartialLine() throws {
        let url = try temp().appendingPathComponent("rollout.jsonl")
        try (start + token(120)).write(to: url, atomically: false, encoding: .utf8)
        var reader = RolloutReader()
        XCTAssertEqual(try reader.read(url).usage?.total, 120)
        XCTAssertEqual(try reader.read(url).usage?.total, 120)
        let line = token(250)
        let midpoint = line.index(line.startIndex, offsetBy: line.count / 2)
        try append(String(line[..<midpoint]), to: url)
        XCTAssertEqual(try reader.read(url).usage?.total, 120)
        try append(String(line[midpoint...]), to: url)
        XCTAssertEqual(try reader.read(url).usage?.total, 250)
        try append("not-json\n" + complete, to: url)
        XCTAssertEqual(try reader.read(url).boundary?.isRunning, false)
        XCTAssertEqual(try reader.read(url).usage?.total, 250)
    }

    func testInitialPartialLineAndLargeBackwardScan() throws {
        let url = try temp().appendingPathComponent("large.jsonl")
        let filler = #"{"type":"response_item","payload":{"text":"ignore transcript"}}"# + "\n"
        let text = start + String(repeating: filler, count: 12_000) + token(120) + String(complete.dropLast())
        try text.write(to: url, atomically: false, encoding: .utf8)
        var reader = RolloutReader()
        XCTAssertEqual(try reader.read(url).boundary?.isRunning, true)
        XCTAssertEqual(try reader.read(url).usage?.total, 120)
        try append("\n", to: url)
        XCTAssertEqual(try reader.read(url).boundary?.isRunning, false)
    }

    func testReplacementAndTruncationResetIncrementalState() throws {
        let url = try temp().appendingPathComponent("rollout.jsonl")
        try (start + token(999999) + complete).write(to: url, atomically: false, encoding: .utf8)
        var reader = RolloutReader()
        XCTAssertEqual(try reader.read(url).usage?.total, 999999)
        try (start + token(20)).write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(try reader.read(url).usage?.total, 20)
        XCTAssertEqual(try reader.read(url).boundary?.isRunning, true)
        try "".write(to: url, atomically: false, encoding: .utf8)
        XCTAssertNil(try reader.read(url).usage)
        XCTAssertNil(try reader.read(url).boundary)
    }

    private func metadata(id: String = "root", source: String = "cli", model: String = "gpt-5.6-sol") -> ThreadMetadata {
        ThreadMetadata(id: id, title: "Test", rolloutPath: "/tmp/session.jsonl", model: model, source: source,
                       updatedAt: Date(timeIntervalSince1970: 1788397200), tokens: 500)
    }

    func testRunningRequiresLiveProcessAndUnfinishedTurn() {
        let meta = metadata()
        let boundary = TurnBoundary(turnID: "turn", isRunning: true, date: .now)
        let rollout = RolloutState(usage: TokenUsage(total: 100), boundary: boundary)
        let live = ProcessEvidence(threadIDs: ["root"])
        XCTAssertEqual(TaskResolver.resolve(metadata: meta, rollout: rollout, storedTurn: nil, evidence: live)?.activity, .running)
        XCTAssertEqual(TaskResolver.resolve(metadata: meta, rollout: rollout, storedTurn: nil, evidence: ProcessEvidence())?.activity, .unknown)
        XCTAssertEqual(TaskResolver.resolve(metadata: meta, rollout: rollout, storedTurn: nil, evidence: ProcessEvidence(threadIDs: ["root"], reliable: false))?.activity, .unknown)
        XCTAssertEqual(TaskResolver.resolve(metadata: meta, rollout: RolloutState(), storedTurn: nil, evidence: live)?.activity, .unknown)
        let terminal = TurnBoundary(turnID: "turn", isRunning: false, date: .now.addingTimeInterval(1))
        XCTAssertNil(TaskResolver.resolve(metadata: meta, rollout: rollout, storedTurn: terminal, evidence: live))
        let legacy = ProcessEvidence(rolloutPaths: [meta.rolloutPath])
        XCTAssertEqual(TaskResolver.resolve(metadata: meta, rollout: rollout, storedTurn: nil, evidence: legacy)?.activity, .running)
    }

    func testSubtasksAndInternalFiltering() {
        let child = metadata(id: "child", source: #"{"subagent":{"thread_spawn":{"parent_thread_id":"root"}}}"#)
        XCTAssertEqual(child.parentID, "root")
        XCTAssertEqual(child.sourceLabel, L10n.text("Subtask"))
        XCTAssertFalse(child.isInternal)
        let guardThread = metadata(source: #"{"subagent":{"other":"guardian"}}"#)
        XCTAssertTrue(guardThread.isInternal)
        XCTAssertTrue(metadata(model: "codex-auto-review").isInternal)
        XCTAssertNil(TaskResolver.resolve(metadata: guardThread, rollout: RolloutState(), storedTurn: nil,
                                         evidence: ProcessEvidence(threadIDs: ["root"])))
    }

    func testInterruptedAndFailedRolloutEventsEndTask() {
        for kind in ["turn_aborted", "task_failed", "task_complete", "task_completed"] {
            var state = RolloutState()
            RolloutEvent.apply(Data(start.utf8), to: &state)
            let line = #"{"type":"event_msg","payload":{"type":"\#(kind)","turn_id":"turn-1"}}"#
            RolloutEvent.apply(Data(line.utf8), to: &state)
            XCTAssertEqual(state.boundary?.isRunning, false, kind)
        }
    }

    func testProcessEvidenceIgnoresOtherProcessesAndCodexHomes() {
        let id = UUID().uuidString.lowercased()
        let home = URL(fileURLWithPath: "/private/tmp/codex-fixture")
        let log = "p12\nccodex\nn\(home.path)/thread-writer-locks/\(id).lock\nn\(home.path)/sessions/rollout.jsonl\nn/private/tmp/other/sessions/x.jsonl\np13\nccat\nn\(home.path)/thread-writer-locks/\(UUID().uuidString).lock\n"
        let evidence = ProcessEvidence.parse(log, home: home)
        XCTAssertEqual(evidence.threadIDs, [id])
        XCTAssertEqual(evidence.rolloutPaths, [home.path + "/sessions/rollout.jsonl"])
    }

    func testSQLiteReadsExistingDataWithoutCreatingMissingDB() throws {
        let folder = try temp(), url = folder.appendingPathComponent("state_5.sqlite")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        sqlite3_exec(db, "CREATE TABLE threads (id TEXT, tokens_used INTEGER); INSERT INTO threads VALUES ('a',120)", nil, nil, nil)
        sqlite3_close(db)
        let reader = try SQLiteReader(url: url)
        XCTAssertEqual(try reader.rows("SELECT * FROM threads").first?["tokens_used"], "120")
        XCTAssertThrowsError(try reader.rows("INSERT INTO threads VALUES ('b',999)"))
        let missing = folder.appendingPathComponent("missing.sqlite")
        XCTAssertThrowsError(try SQLiteReader(url: missing))
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        XCTAssertEqual(SQLiteReader.database(named: "state", in: folder)?.resolvingSymlinksInPath(), url.resolvingSymlinksInPath())
    }

    func testRPCHandshakeRepeatedReadsAndSidecarCleanup() async throws {
        let home = try temp()
        let executable = home.appendingPathComponent("fake-codex")
        let script = #"""
        #!/bin/sh
        while IFS= read -r request; do
          printf '%s\n' "$request" >> "$CODEX_HOME/requests"
          rpc_id=${request##*'"id":'}
          rpc_id=${rpc_id%%,*}
          rpc_id=${rpc_id%%\}*}
          case "$request" in
            *'"method":"initialize"'*) printf '%s\n' '{"id":'"$rpc_id"',"result":{}}' ;;
            *'"method":"account/read"'*) printf '%s\n' '{"id":'"$rpc_id"',"result":{"account":{"type":"chatgpt","email":"fixture@example.invalid"}}}' ;;
            *'"method":"account/rateLimits/read"'*) printf '%s\n' '{"id":'"$rpc_id"',"result":{"accountId":"fixture-account","rateLimits":{"primary":{"usedPercent":25,"windowDurationMins":300}},"rateLimitResetCredits":{"availableCount":2,"credits":[{"status":"available","expiresAt":1900000000},{"status":"available","expiresAt":1900000000}]}}}' ;;
          esac
        done
        """#
        try script.write(to: executable, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let client = AppServerClient(requestTimeout: .seconds(2))
        let location = CodexLocation(home: home, executable: executable)
        let first = await client.fetch(location: location)
        let second = await client.fetch(location: location)
        await client.shutdown()
        XCTAssertNil(first.error)
        XCTAssertEqual(first.snapshot?.menuWindow?.remainingPercent, 75)
        XCTAssertEqual(second.snapshot?.menuWindow?.remainingPercent, 75)
        XCTAssertEqual(first.snapshot?.resetCredits?.availableCount, 2)
        XCTAssertEqual(second.snapshot?.resetCredits?.expiryGroups.map(\.count), [2])
        XCTAssertEqual(first.account?.identity, "fixture-account")
        let requests = try String(contentsOf: home.appendingPathComponent("requests"), encoding: .utf8)
            .split(separator: "\n").map { try json(String($0))["method"].string }
        XCTAssertEqual(requests, ["initialize", "initialized", "account/read", "account/rateLimits/read", "account/read", "account/rateLimits/read"])
    }

    func testRPCMissingExecutableAndTimeoutAreRecoverable() async throws {
        let home = try temp()
        let missing = AppServerClient()
        let noCLI = await missing.fetch(location: CodexLocation(home: home, executable: nil))
        XCTAssertNotNil(noCLI.error)
        let executable = home.appendingPathComponent("slow-codex")
        try "#!/bin/sh\nwhile IFS= read -r request; do :; done\n".write(to: executable, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let slow = AppServerClient(requestTimeout: .milliseconds(100))
        let result = await slow.fetch(location: CodexLocation(home: home, executable: executable))
        XCTAssertEqual(result.error, .timeout)
        await slow.shutdown()
    }
}
