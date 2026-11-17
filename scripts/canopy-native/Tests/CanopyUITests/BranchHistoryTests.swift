import CanopyCore
import Foundation
import Testing
@testable import CanopyUI

@MainActor struct BranchHistoryTests {
    func source(_ name: String = "a", tip: String = "tip", parentTip: String = "p1", git: Int = 1, epoch: String = "epoch", hydration: Int = 1) -> BranchHistory.Source {
        BranchSource(repo: "r", name: name, tip: tip, parent: "main", upstream: "origin/\(name)", pushed: "synced", ahead: 0,
                     epoch: epoch, git: git, remote: 1, hydration: hydration).forHistory(parentTip: parentTip)
    }

    @Test func anotherBranchsCommitLeavesTheHistoryKeyAlone() {
        // every commit anywhere in the repo bumps the git version; with agents committing across
        // the repo, keying on it cancelled each slow read before it landed (2026-11-17)
        #expect(source(git: 1) == source(git: 2))
        #expect(source(parentTip: "p1") != source(parentTip: "p2"), "the parent moving changes which commits are the branch's own")
        #expect(source(tip: "a") != source(tip: "b"))
    }

    @Test func aReadCoalescesAndAValidEmptyResultIsReady() async {
        let s = source()
        var calls = 0
        let history = BranchHistory(source: { _ in s }, read: { _ in calls += 1; return [] })
        #expect(history.state(s.id) == .idle)
        let task = history.load(s.id)
        #expect(history.state(s.id) == .loading)
        history.load(s.id)
        await task?.value
        #expect(calls == 1 && history.rows(s.id) == [])
        #expect(history.stamp(s.id) != nil)
        history.load(s.id)
        #expect(calls == 1)
    }

    @Test func failureIsTerminalUntilExplicitRetryOrANewSource() async {
        var s = source()
        var calls = 0
        let history = BranchHistory(source: { _ in s }, read: { _ in calls += 1; throw Refusal("fixture unavailable") })
        await history.load(s.id)?.value
        #expect(history.state(s.id) == .failed && history.rows(s.id) == nil)
        #expect(history.load(s.id) == nil && calls == 1)
        history.read = { _ in calls += 1; return [] }
        await history.load(s.id, retry: true)?.value
        #expect(history.state(s.id) == .ready([]) && calls == 2)
        s = source(parentTip: "p2")
        #expect(history.state(s.id) == .ready([]) && history.isStale(s.id), "a moved key keeps the rows on screen")
        await history.load(s.id)?.value
        #expect(calls == 3 && !history.isStale(s.id))
    }

    @Test func aKeyThatMovesMidReadNeverCancelsIt() async throws {
        // a reshape rebases the branch or its parent faster than a slow read completes; restarting
        // on each move starved the page at "reading the commits…" (2026-11-17)
        var s = source(tip: "t1")
        var pending: [(source: BranchHistory.Source, k: CheckedContinuation<[HistoryCommit], Error>)] = []
        let history = BranchHistory(source: { _ in s }, read: { src in try await withCheckedThrowingContinuation { pending.append((src, $0)) } })
        history.debounceNanos = 0
        let task = history.load(s.id)
        for _ in 0..<100 where pending.count < 1 { await Task.yield() }
        s = source(tip: "t2")
        #expect(history.load(s.id) == task, "the view's reload joins the read in flight")
        try #require(pending.count == 1)
        pending[0].k.resume(returning: [HistoryCommit(sha: "t1", subject: "T1")])
        for _ in 0..<100 where pending.count < 2 { await Task.yield() }
        #expect(history.rows(s.id)?.map(\.sha) == ["t1"] && history.isStale(s.id), "the completed read is drawn, marked stale")
        try #require(pending.count == 2)
        #expect(pending[1].source.tip == "t2")
        pending[1].k.resume(returning: [HistoryCommit(sha: "t2", subject: "T2")])
        await task?.value
        #expect(history.rows(s.id)?.map(\.sha) == ["t2"] && !history.isStale(s.id))
    }

    @Test func aBurstOfMovesFoldsIntoOneFollowUpRead() async throws {
        var s = source(tip: "t1")
        var reads: [String] = []
        let history = BranchHistory(source: { _ in s }, read: { src in reads.append(src.tip); return [] })
        history.debounceNanos = 200_000_000
        await history.load(s.id)?.value
        var last: Task<Void, Never>?
        for tip in ["t2", "t3", "t4"] { s = source(tip: tip); last = history.load(s.id) ?? last }
        await last?.value
        #expect(reads == ["t1", "t4"], "three moves within the debounce are one revalidation, at the newest key")
        #expect(history.rows(s.id) == [] && !history.isStale(s.id))
    }

    @Test func outOfOrderBranchesCannotEvictEachOthersResults() async {
        let a = source(), b = source("b")
        var pending: [String: CheckedContinuation<[HistoryCommit], Error>] = [:]
        let history = BranchHistory(source: { $0 == a.id ? a : b }, read: { source in
            try await withCheckedThrowingContinuation { pending[source.id] = $0 }
        })
        let first = history.load(a.id), second = history.load(b.id)
        for _ in 0..<100 where pending.count != 2 { await Task.yield() }
        pending[b.id]?.resume(returning: [HistoryCommit(sha: "b1", subject: "B")])
        await second?.value
        pending[a.id]?.resume(returning: [HistoryCommit(sha: "a1", subject: "A")])
        await first?.value
        #expect(history.rows(a.id)?.map(\.sha) == ["a1"])
        #expect(history.rows(b.id)?.map(\.sha) == ["b1"])
    }

    @Test func aRetryMidReadFollowsItAndAMovedKeyKeepsTheRowsAndTheirStamp() async throws {
        var s = source()
        var pending: [CheckedContinuation<[HistoryCommit], Error>] = []
        let history = BranchHistory(source: { _ in s }, read: { _ in try await withCheckedThrowingContinuation { pending.append($0) } })
        history.debounceNanos = 0
        let first = history.load(s.id)
        for _ in 0..<100 where pending.count < 1 { await Task.yield() }
        #expect(history.load(s.id, retry: true) == first, "a retry mid-read follows the read in flight, never cancels it")
        try #require(pending.count == 1)
        pending[0].resume(returning: [HistoryCommit(sha: "old", subject: "Old")])
        for _ in 0..<100 where pending.count < 2 { await Task.yield() }
        try #require(pending.count == 2)
        pending[1].resume(returning: [HistoryCommit(sha: "new", subject: "New")])
        await first?.value
        #expect(history.rows(s.id)?.first?.sha == "new")
        let stamp = history.stamp(s.id)
        s = source(epoch: "new-epoch", hydration: 2)
        #expect(history.rows(s.id)?.first?.sha == "new" && history.isStale(s.id))
        #expect(history.stamp(s.id) == nil, "stale rows draw, but a pick can't bind to them")
        history.put(s.id, rows: [])
        #expect(history.stamp(s.id) != nil && history.stamp(s.id) != stamp && !history.isStale(s.id))
    }

    @Test func lateFailureCannotPublishUnderChangedSourceAndRemovedBranch() async {
        var s: BranchHistory.Source? = source()
        var pending: CheckedContinuation<[HistoryCommit], Error>?
        let history = BranchHistory(source: { _ in s }, read: { _ in try await withCheckedThrowingContinuation { pending = $0 } })
        let task = history.load("r:a")
        for _ in 0..<100 where pending == nil { await Task.yield() }
        s = nil
        pending?.resume(throwing: Refusal("old failure"))
        await task?.value
        #expect(history.state("r:a") == .idle)
        #expect(history.load("r:a") == nil)
    }

    @Test func importedRowsRetirePendingReadsAndKeepOnlyOwnedCommits() async throws {
        let s = source()
        var pending: CheckedContinuation<[HistoryCommit], Error>?
        let history = BranchHistory(source: { _ in s }, read: { _ in try await withCheckedThrowingContinuation { pending = $0 } })
        let task = history.load(s.id)
        for _ in 0..<100 where pending == nil { await Task.yield() }
        let request = try #require(pending)
        history.put(s.id, rows: [HistoryCommit(sha: "own", subject: "Own"), HistoryCommit(sha: "parent", subject: "Parent", own: false)])
        let stamp = history.stamp(s.id)
        request.resume(returning: [HistoryCommit(sha: "obsolete", subject: "Obsolete")])
        await task?.value
        #expect(history.rows(s.id)?.map(\.sha) == ["own"])
        #expect(history.stamp(s.id) == stamp)
    }

    @Test func retainedBranchesAreBounded() async {
        var sources: [String: BranchHistory.Source] = [:]
        let history = BranchHistory(source: { sources[$0] }, read: { _ in [] })
        for index in 0..<65 {
            let s = source("b\(index)"); sources[s.id] = s
            history.put(s.id, rows: [])
        }
        #expect(history.state("r:b0") == .idle)
        #expect(history.state("r:b64") == .ready([]))
        history.read = { _ in [HistoryCommit(sha: "fresh", subject: "Fresh")] }
        await history.load("r:b0")?.value
        #expect(history.rows("r:b0")?.first?.sha == "fresh")
        #expect(history.state("r:b1") == .idle)
    }
}
