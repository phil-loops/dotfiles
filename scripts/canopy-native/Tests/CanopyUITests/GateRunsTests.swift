import CanopyCore
import Foundation
import Testing
@testable import CanopyUI

@Suite struct GateProgressSummaryTests {
    @Test func theCurrentGateAndCompletedCountComeFromThePlan() {
        let progress = GateProgress(running: true, events: [
            GateEvent(event: "plan", planned: ["env", "fresh", "lint", "tests"]),
            GateEvent(event: "done", gate: "env", ok: true, ms: 1000),
            GateEvent(event: "done", gate: "fresh", ok: true, ms: 50),
            GateEvent(event: "start", gate: "lint", ts: 72),
        ])
        let summary = GateProgressSummary(progress, now: 100)
        #expect(summary.complete == 2 && summary.rows.count == 4)
        #expect(summary.activity == "lint" && summary.time == "28s")
        #expect(summary.rows.map(\.state) == [.green, .green, .running, .queued])
    }

    @Test func setupDoesNotInventAPlan() {
        let progress = GateProgress(running: true, elapsed: 12, events: [GateEvent(event: "setup", step: "queue", position: 3)])
        let summary = GateProgressSummary(progress, now: 100)
        #expect(summary.rows.isEmpty && summary.complete == 0)
        #expect(summary.activity == "queued #3" && summary.time == "12s")
    }

    @Test func terminalAndStoppedRunsCannotKeepAClockRunning() {
        let events = [GateEvent(event: "plan", planned: ["env", "tests"]), GateEvent(event: "done", gate: "env", ok: true), GateEvent(event: "start", gate: "tests", ts: 5)]
        let stopped = GateProgressSummary(GateProgress(running: true, events: events, dead: true), now: 100)
        #expect(stopped.activity == "stopped" && stopped.time == nil && stopped.complete == 1)
        let failed = GateProgressSummary(GateProgress(running: true, events: events + [GateEvent(event: "done", gate: "tests", ok: false), GateEvent(event: "result", ok: false)]), now: 100)
        #expect(failed.activity == "tests failed" && failed.time == nil && failed.complete == 2)
    }

    @Test func aMissingPlanDoesNotClaimChecksPassed() {
        let summary = GateProgressSummary(GateProgress(running: false), now: 100)
        #expect(summary.rows.isEmpty && summary.activity == "no steps reported")
    }

    @Test func unstartedChecksDoNotCountAsCompleted() {
        let summary = GateProgressSummary(GateProgress(running: false, events: [
            GateEvent(event: "plan", planned: ["env", "lint", "tests"]),
            GateEvent(event: "done", gate: "env", ok: false),
            GateEvent(event: "result", ok: false),
        ]), now: 100)
        #expect(summary.complete == 1 && summary.rows.count == 3)
        #expect(summary.rows.map(\.state) == [.red, .skipped, .skipped])
    }
}
