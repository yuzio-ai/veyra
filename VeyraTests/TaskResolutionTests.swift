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
                                                      storedTurn: stored, evidence: evidence)
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
}
