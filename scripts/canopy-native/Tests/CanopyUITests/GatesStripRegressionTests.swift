import CanopyCore
import Foundation
import Testing
@testable import CanopyUI

/// Regression tests for canopy-todo `keep-the-gates-strip-on-screen-from-p-until-the-run-ends`:
/// after `p` the branch says its gates are running before the server has started the run, so the
/// first progress read answers the PREVIOUS, finished run. Both tests reproduce that bug today and
/// sit in `withKnownIssue`; the fix makes them pass, and then the wrappers must come off.
@Suite struct GatesStripStaleProgressTests {
    let plan = GateEvent(event: "plan", planned: ["env", "typecheck", "tests"])

    @Test func aRunPressedOverAFinishedOneStillSaysGatesStarting() {
        let previous = GateProgress(running: false, elapsed: 300, events: [plan,
            GateEvent(event: "done", gate: "env", ok: true, ms: 900),
            GateEvent(event: "done", gate: "typecheck", ok: true, ms: 900),
            GateEvent(event: "done", gate: "tests", ok: true, ms: 900),
            GateEvent(event: "result", ok: true)])
        let w = GatesRun.waiting(previous, rows: GatesRun.rows(previous, now: 400), inFlight: true, now: 400)
        withKnownIssue("GatesRun.waiting returns nil on the previous run's result event, so the strip goes blank") {
            #expect(w?.text == "gates starting", "a branch whose gates are in flight always says what they're doing")
            #expect(w?.secs == nil, "the finished run's time doesn't stand on the new run")
        }
    }
}

@MainActor @Suite struct GatesProgressPollingTests {
    @Test func progressIsReadAgainWhileTheBranchSaysRunning() async throws {
        let ship = ShipTests()
        let (a, port) = try ship.app { s in ship.entity(&s, "branch", ShipTests.branch) { $0["gates"] = "running" } }
        ShipStub.answer(port, "GET", "/loops/gates-progress", #"{"running": false, "events": [{"event": "result", "ok": true}]}"#)
        let b = try #require(a.store.view(Branch.self, ShipTests.branch))
        func reads() -> Int {
            ShipStub.lock.withLock { (ShipStub.seen["\(port)"] ?? []).filter { $0.method == "GET" && $0.path.hasSuffix("/gates-progress") }.count }
        }
        ShipState.of(a).readProgress(a, b, key: "\(b.tip)|running|", gate: nil)
        let t0 = Date()
        while reads() < 2, Date().timeIntervalSince(t0) < 6 { try await Task.sleep(nanoseconds: 50_000_000) }
        #expect(reads() >= 1, "the first read went out")
        withKnownIssue("readProgress re-polls only while the last answer said running, so a stale finished answer ends the polling") {
            #expect(reads() >= 2, "while the branch says its gates are running, progress is read again")
        }
    }
}
