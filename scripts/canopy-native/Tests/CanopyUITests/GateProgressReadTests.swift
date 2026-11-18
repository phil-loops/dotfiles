import Foundation
import Testing
@testable import CanopyUI

@MainActor @Suite(.serialized) struct GateProgressReadTests {
    let first = GateProgressRead.Source(repo: "loops", branch: "first", tip: "a", tree: "tree-a")
    let second = GateProgressRead.Source(repo: "loops", branch: "second", tip: "b", tree: "tree-b")

    @Test func aVisibleRunningBranchKeepsReadingPastAnOldFinishedJournal() async {
        let reader = GateProgressRead()
        var reads = 0
        var pauses = 0
        await reader.watch(first, read: { _ in
            reads += 1
            return GateProgress(running: reads == 2)
        }, pause: {
            pauses += 1
            if reads == 3 { throw CancellationError() }
        })
        #expect(reads == 3 && pauses == 3)
        #expect(reader.status(for: first) == .observed(GateProgress(running: false)))
        #expect(reader.status(for: second) == .loading)
    }

    @Test func aFailedReadSaysUnavailableAndCanRecover() async {
        enum Failed: Error { case read }
        let reader = GateProgressRead()
        var reads = 0
        var whileWaiting: GateProgressRead.Status?
        await reader.watch(first, read: { _ in
            reads += 1
            if reads == 1 { throw Failed.read }
            return GateProgress(running: false)
        }, pause: {
            if reads == 2 { throw CancellationError() }
            whileWaiting = reader.status(for: first)
        })
        #expect(whileWaiting == .unavailable)
        #expect(reads == 2)
        #expect(reader.status(for: first) == .observed(GateProgress(running: false)))
    }

    @Test func aCanceledViewCannotAcceptALateObservation() async {
        let reader = GateProgressRead()
        var held: CheckedContinuation<GateProgress, Error>?
        let task = Task { await reader.watch(first, read: { _ in try await withCheckedThrowingContinuation { held = $0 } }) }
        await until("the held progress read") { held != nil }
        task.cancel()
        held?.resume(returning: GateProgress(running: false))
        await task.value
        #expect(reader.status(for: first) == .loading)
    }

    @Test func anEarlierReadCannotReplaceANewerBranch() async {
        let reader = GateProgressRead()
        var held: CheckedContinuation<GateProgress, Error>?
        let old = Task { await reader.watch(first, read: { _ in try await withCheckedThrowingContinuation { held = $0 } }) }
        await until("the first branch's read") { held != nil }
        let newest = GateProgress(running: false, events: [GateEvent(event: "plan", planned: ["newest"])])
        await reader.watch(second, read: { _ in newest }, pause: { throw CancellationError() })
        held?.resume(returning: GateProgress(running: false))
        await old.value
        #expect(reader.status(for: second) == .observed(newest))
        #expect(reader.status(for: first) == .loading)
    }

    @Test func returningToTheSameSourceCannotReviveAnOldRead() async {
        let reader = GateProgressRead()
        var held: CheckedContinuation<GateProgress, Error>?
        let old = Task { await reader.watch(first, read: { _ in try await withCheckedThrowingContinuation { held = $0 } }) }
        await until("the old read") { held != nil }
        await reader.watch(second, read: { _ in GateProgress(running: false) }, pause: { throw CancellationError() })
        let newest = GateProgress(running: false, events: [GateEvent(event: "plan", planned: ["newest"])])
        await reader.watch(first, read: { _ in newest }, pause: { throw CancellationError() })
        held?.resume(returning: GateProgress(running: false))
        await old.value
        #expect(reader.status(for: first) == .observed(newest))
    }

    @Test func cancellationBetweenPollsDoesNotReadAgain() async {
        let reader = GateProgressRead()
        var reads = 0
        await reader.watch(first, read: { _ in reads += 1; return GateProgress(running: true) }, pause: { throw CancellationError() })
        #expect(reads == 1)
    }
}

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
