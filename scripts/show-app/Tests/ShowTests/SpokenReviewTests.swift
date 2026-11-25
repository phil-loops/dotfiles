import Foundation
import Testing
@testable import Show

/// Where a spoken review can start, and which canopy addresses count as one place on its trail.
struct SpokenReviewTests {
    @Test func aReviewStartsFromAForestOrABranchPage() {
        #expect(SpokenReview.scope(of: "/v2/p/loops/lock-user-delete")! == ("lock-user-delete", nil))
        #expect(SpokenReview.scope(of: "/v2/b/loops/feat/x?file=a.ts&line=4")! == (nil, "feat/x"), "a branch name keeps its slashes")
        #expect(SpokenReview.scope(of: "/v2/machine") == nil)
        #expect(SpokenReview.scope(of: "/v2/b/other/x") == nil, "only the loops repo's branches resolve to commits")
    }

    @Test func scrollingAndSplitsAreTheSamePlace() {
        #expect(SpokenReview.spot("/v2/b/loops/x?file=a.ts&line=4&row=12&win=1,0") == "/v2/b/loops/x?file=a.ts&line=4")
        #expect(SpokenReview.spot("/v2/b/loops/x?row=3") == "/v2/b/loops/x")
    }
}

/// What the title bar says as Dictate's files appear in a review's folder.
struct SpokenReviewStateTests {
    @Test func theTitleFollowsRecordingStoppingAndTranscribing() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("review-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let review = SpokenReview(dir: dir, title: "domain-notices", repoPath: "/nonexistent")
        func write(_ name: String, _ json: String) throws { try Data(json.utf8).write(to: dir.appendingPathComponent(name)) }
        try write("recording.json", #"{"startUptimeNs":1}"#)
        #expect(review.state == .recording && review.status == "● reviewing domain-notices · ⌘⇧R finishes")
        try write("stopped.json", #"{"stoppedUptimeNs":2}"#)
        #expect(review.state == .transcribing(done: 0, total: 0) && review.status == "transcribing your review…", "🎤 stopped it")
        try write("progress.json", #"{"done":3,"total":7}"#)
        #expect(review.status == "transcribing your review · 3 of 7")
        try write("notes.md", "## x")
        #expect(review.state == .done)
    }
}

/// What an Inbox arrival's notification says: the newest message's title and its opening in plain words.
struct InboxNoticeTests {
    @Test func theNoticeCarriesTheVerdictNotTheWordInbox() throws {
        let deck = ###"{"sections":[{"title":"Since your review · domain-notices","body":"## Needs your eyes\n- Two things: **[notify](canopy://v2/b/loops/notify)** reads top to bottom, and `owners` is new.\n- Everything else is done."}]}"###
        let newest = try #require(ArrivalNotices.newestMessage(inInbox: Data(deck.utf8)))
        #expect(newest.title == "Since your review · domain-notices")
        #expect(newest.body == "Two things: notify reads top to bottom, and owners is new.")
        #expect(ArrivalNotices.gist(of: String(repeating: "word ", count: 80), width: 20) == "word word word word…")
        #expect(ArrivalNotices.newestMessage(inInbox: Data("{}".utf8)) == nil)
    }
}
