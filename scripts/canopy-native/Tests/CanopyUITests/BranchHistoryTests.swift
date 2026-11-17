import CanopyCore
import Foundation
import Testing
@testable import CanopyUI

@MainActor struct BranchHistoryTests {
    func source(_ name: String = "a", tip: String = "tip", git: Int = 1, epoch: String = "epoch", hydration: Int = 1) -> BranchHistory.Source {
        .init(repo: "r", name: name, tip: tip, parent: "main", upstream: "origin/\(name)", pushed: "synced", ahead: 0,
              epoch: epoch, git: git, remote: 1, hydration: hydration)
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
        s = source(git: 2)
        #expect(history.state(s.id) == .idle)
        await history.load(s.id)?.value
        #expect(calls == 3)
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

    @Test func retriesAndSourceRoundTripsRevokeOldCompletionsAndAnchors() async throws {
        var s = source()
        var pending: [CheckedContinuation<[HistoryCommit], Error>] = []
        let history = BranchHistory(source: { _ in s }, read: { _ in try await withCheckedThrowingContinuation { pending.append($0) } })
        let first = history.load(s.id)
        for _ in 0..<100 where pending.count < 1 { await Task.yield() }
        let second = history.load(s.id, retry: true)
        for _ in 0..<100 where pending.count < 2 { await Task.yield() }
        try #require(pending.count == 2)
        pending[1].resume(returning: [HistoryCommit(sha: "new", subject: "New")])
        await second?.value
        let stamp = history.stamp(s.id)
        pending[0].resume(returning: [HistoryCommit(sha: "old", subject: "Old")])
        await first?.value
        #expect(history.rows(s.id)?.first?.sha == "new")
        #expect(history.stamp(s.id) == stamp)
        s = source(epoch: "new-epoch", hydration: 2)
        #expect(history.rows(s.id) == nil && history.stamp(s.id) == nil)
        s = source(hydration: 3)
        #expect(history.rows(s.id) == nil)
        history.put(s.id, rows: [])
        #expect(history.stamp(s.id) != stamp)
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
