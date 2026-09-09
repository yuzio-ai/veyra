import XCTest
import Foundation

final class TaskResolutionTests: XCTestCase {
    private let second = Date(timeIntervalSince1970: 1_788_396_000)
    private var metadata: ThreadMetadata {
        ThreadMetadata(id: "root", title: "Fixture", rolloutPath: "/tmp/fixture.jsonl", model: nil,
                       source: "cli", updatedAt: second, tokens: 100)
    }

    func testSameTurnCompletionFailureAndInterruptionOverrideFractionalStart() {
        let started = TurnBoundary(turnID: "turn", isRunning: true, date: second.addingTimeInterval(0.5))
        let finished = TurnBoundary(turnID: "turn", isRunning: false, date: second)
        for kind in ["task_complete", "task_completed", "task_failed", "turn_failed", "turn_aborted"] {
            var endedLog = RolloutState()
            let line = #"{"type":"event_msg","timestamp":"2026-09-03T01:00:00.800Z","payload":{"type":"\#(kind)","turn_id":"turn"}}"#
            RolloutEvent.apply(Data(line.utf8), to: &endedLog)
            XCTAssertNil(TaskResolver.resolve(metadata: metadata, rollout: endedLog, storedTurn: started,
                                              evidence: ProcessEvidence(threadIDs: ["root"])), kind)
            XCTAssertNil(TaskResolver.resolve(metadata: metadata, rollout: RolloutState(boundary: started),
                                              storedTurn: finished, evidence: ProcessEvidence(threadIDs: ["root"])), kind)
        }
        XCTAssertEqual(TaskResolver.mergeBoundaries(rollout: started, stored: finished), .known(finished))
        XCTAssertEqual(TaskResolver.mergeBoundaries(rollout: finished, stored: started), .known(finished))
    }

    func testSameTurnKeepsPreciseLogTimeAndFallsBackToDatabaseTime() {
        for running in [true, false] {
            let precise = TurnBoundary(turnID: "turn", isRunning: running, date: second.addingTimeInterval(0.5))
            let coarse = TurnBoundary(turnID: "turn", isRunning: running, date: second)
            let undated = TurnBoundary(turnID: "turn", isRunning: running, date: nil)
            XCTAssertEqual(TaskResolver.mergeBoundaries(rollout: precise, stored: coarse), .known(precise))
            XCTAssertEqual(TaskResolver.mergeBoundaries(rollout: undated, stored: coarse), .known(coarse))
        }
    }

    func testNewerTurnIsNotHiddenByOlderTerminalState() {
        let old = TurnBoundary(turnID: "old", isRunning: false, date: second.addingTimeInterval(0.9))
        let new = TurnBoundary(turnID: "new", isRunning: true, date: second.addingTimeInterval(1))
        for (file, stored) in [(old, new), (new, old)] {
            XCTAssertEqual(TaskResolver.mergeBoundaries(rollout: file, stored: stored), .known(new))
            let result = TaskResolver.resolve(metadata: metadata, rollout: RolloutState(boundary: file), storedTurn: stored,
                                              evidence: ProcessEvidence(threadIDs: ["root"]))
            XCTAssertEqual(result?.activity, .running)
            XCTAssertEqual(result?.startedAt, new.date)
        }
    }

    func testAmbiguousTurnOrderNeverClaimsRunningOrAnEstimatedStart() {
        let started = TurnBoundary(turnID: "new", isRunning: true, date: second.addingTimeInterval(0.5))
        let conflicts = [
            TurnBoundary(turnID: "old", isRunning: false, date: second),
            TurnBoundary(turnID: nil, isRunning: false, date: second),
            TurnBoundary(turnID: "", isRunning: true, date: second),
            TurnBoundary(turnID: "old", isRunning: false, date: nil)
        ]
        for conflict in conflicts {
            for (file, stored) in [(started, conflict), (conflict, started)] {
                XCTAssertEqual(TaskResolver.mergeBoundaries(rollout: file, stored: stored), .ambiguous)
                for evidence in [ProcessEvidence(), ProcessEvidence(threadIDs: ["root"])] {
                    let result = TaskResolver.resolve(metadata: metadata, rollout: RolloutState(boundary: file),
                                                      storedTurn: stored, evidence: evidence, now: second.addingTimeInterval(1))
                    XCTAssertEqual(result?.activity, .unknown)
                    XCTAssertNil(result?.startedAt)
                }
            }
        }
        let missingID = TurnBoundary(turnID: nil, isRunning: true, date: second)
        XCTAssertEqual(TaskResolver.mergeBoundaries(rollout: missingID, stored: missingID), .ambiguous)
    }

    func testMissingIDsStillAllowOrderingAcrossSecondsAndBothTerminalsAreExcluded() {
        let old = TurnBoundary(turnID: nil, isRunning: true, date: second)
        let newer = TurnBoundary(turnID: nil, isRunning: false, date: second.addingTimeInterval(1))
        XCTAssertEqual(TaskResolver.mergeBoundaries(rollout: old, stored: newer), .known(newer))
        let undated = TurnBoundary(turnID: "other", isRunning: false, date: nil)
        XCTAssertNil(TaskResolver.resolve(metadata: metadata, rollout: RolloutState(boundary: newer),
                                          storedTurn: undated, evidence: ProcessEvidence(threadIDs: ["root"])))
        XCTAssertEqual(TaskResolver.mergeBoundaries(rollout: nil, stored: nil), .absent)
        XCTAssertEqual(TaskResolver.mergeBoundaries(rollout: old, stored: nil), .known(old))
        XCTAssertEqual(TaskResolver.mergeBoundaries(rollout: nil, stored: newer), .known(newer))
    }

    func testUnfinishedAndAmbiguousTasksExpireExactlyAt24Hours() {
        let started = TurnBoundary(turnID: "new", isRunning: true, date: second)
        let conflict = TurnBoundary(turnID: "old", isRunning: false, date: second)
        for stored in [nil, conflict] {
            let rollout = RolloutState(boundary: started)
            for age in [86_399.999, 86_400, 86_401] {
                let task = TaskResolver.resolve(metadata: metadata, rollout: rollout, storedTurn: stored,
                    evidence: ProcessEvidence(), now: second.addingTimeInterval(age))
                XCTAssertEqual(task?.activity, age < 86_400 ? .unknown : nil)
            }
        }
    }

    func testOldTasksAreRetainedWithProcessEvidenceOrFailedProcessCheck() {
        let rollout = RolloutState(boundary: TurnBoundary(turnID: "one", isRunning: true, date: second))
        let now = second.addingTimeInterval(180 * 86_400)
        for evidence in [ProcessEvidence(threadIDs: ["root"]),
                         ProcessEvidence(rolloutPaths: [metadata.rolloutPath]),
                         ProcessEvidence(reliable: false),
                         ProcessEvidence(threadIDs: ["root"], reliable: false)] {
            let task = TaskResolver.resolve(metadata: metadata, rollout: rollout, storedTurn: nil,
                evidence: evidence, now: now)
            XCTAssertEqual(task?.activity, evidence.reliable ? .running : .unknown)
        }
    }

    func testLatestActivityFromEachRecordKeepsAnOldTaskVisible() {
        let now = second.addingTimeInterval(2 * 86_400)
        let recent = now.addingTimeInterval(-60)
        for source in 0..<4 {
            let meta = ThreadMetadata(id: "root", title: "Fixture", rolloutPath: "/tmp/fixture.jsonl", model: nil,
                source: "cli", updatedAt: source == 0 ? recent : second, tokens: nil)
            let rollout = RolloutState(usageDate: source == 1 ? recent : second,
                boundary: TurnBoundary(turnID: "one", isRunning: true, date: source == 2 ? recent : second))
            let stored = TurnBoundary(turnID: "one", isRunning: true, date: source == 3 ? recent : second)
            XCTAssertEqual(TaskResolver.resolve(metadata: meta, rollout: rollout, storedTurn: stored,
                evidence: ProcessEvidence(), now: now)?.activity, .unknown, "source \(source)")
        }
    }

    func testInvalidActivityTimesAreIgnoredAndMissingOrFutureTimesStayUnknown() {
        let now = second.addingTimeInterval(2 * 86_400)
        for seconds in [Double.nan, .infinity, -.infinity, 0, -1] {
            let invalid = Date(timeIntervalSince1970: seconds)
            let meta = ThreadMetadata(id: "root", title: "Fixture", rolloutPath: "/tmp/fixture.jsonl", model: nil,
                source: "cli", updatedAt: invalid, tokens: nil)
            let rollout = RolloutState(usageDate: invalid,
                boundary: TurnBoundary(turnID: "one", isRunning: true, date: invalid))
            XCTAssertEqual(TaskResolver.resolve(metadata: meta, rollout: rollout, storedTurn: nil,
                evidence: ProcessEvidence(), now: now)?.activity, .unknown)
            XCTAssertNil(TaskResolver.resolve(metadata: metadata, rollout: rollout, storedTurn: nil,
                evidence: ProcessEvidence(), now: now), "Invalid times must not override valid old metadata")
        }
        let undated = RolloutState(boundary: TurnBoundary(turnID: "one", isRunning: true, date: nil))
        let missing = ThreadMetadata(id: "root", title: "Fixture", rolloutPath: "/tmp/fixture.jsonl", model: nil,
            source: "cli", updatedAt: Date(timeIntervalSince1970: 0), tokens: nil)
        XCTAssertEqual(TaskResolver.resolve(metadata: missing, rollout: undated, storedTurn: nil,
            evidence: ProcessEvidence(), now: now)?.activity, .unknown)
        let future = RolloutState(usageDate: now.addingTimeInterval(60), boundary: undated.boundary)
        XCTAssertEqual(TaskResolver.resolve(metadata: metadata, rollout: future, storedTurn: nil,
            evidence: ProcessEvidence(), now: now)?.activity, .unknown)
    }

    func testCompletionStillWinsOverRecentActivityAndUnreliableProcesses() {
        let started = TurnBoundary(turnID: "one", isRunning: true, date: second)
        let ended = TurnBoundary(turnID: "one", isRunning: false, date: second)
        for evidence in [ProcessEvidence(), ProcessEvidence(reliable: false), ProcessEvidence(threadIDs: ["root"])] {
            XCTAssertNil(TaskResolver.resolve(metadata: metadata,
                rollout: RolloutState(usageDate: second.addingTimeInterval(100), boundary: started),
                storedTurn: ended, evidence: evidence, now: second.addingTimeInterval(101)))
        }
    }
}
