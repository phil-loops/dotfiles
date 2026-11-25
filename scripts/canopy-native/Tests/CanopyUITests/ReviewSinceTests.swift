import Foundation
import Testing
@testable import CanopyUI

/// What changed since Phil's last spoken review (show-review-reply's since.json): trusted only while a branch's tip is
/// the one the answer was written for, and read from the newest review of that forest in that repo.
@Suite struct ReviewSinceTests {
    static func entry(_ kind: String, tip: String = "t1", why: String? = "n6", eyes: [ReviewSince.Answer] = [],
                      notes: [ReviewSince.Note] = []) -> ReviewSince.Entry {
        ReviewSince.Entry(kind: kind, was: nil, tipThen: "t0", tipNow: tip, why: why, changed: ["a.ts"], added: ["b.ts"], dropped: ["c.ts"], notes: notes, needsEyes: eyes)
    }

    static let partly = ReviewSince.Answer(id: "n7d", state: "partly", commits: "5c3e", text: "still a hard-coded cap")
    static let done = ReviewSince.Answer(id: "n7b", state: "done", commits: "0e22", text: "full id")
    static let liked = ReviewSince.Answer(id: "n13", state: "no ask", commits: "", text: "liked")

    @Test func aBranchStandsAgainstTheReviewOnlyAtTheTipTheAnswerWasWrittenFor() {
        let s = ReviewSince(forest: "f", branches: [
            "same": Self.entry("same"), "asked": Self.entry("asked"), "unasked": Self.entry("unasked"), "new": Self.entry("new"),
            "eyes": Self.entry("asked", eyes: [Self.partly]),
        ])
        #expect(s.mark("same", tip: "t1") == .same && s.mark("asked", tip: "t1") == .asked && s.mark("unasked", tip: "t1") == .unasked)
        #expect(s.mark("new", tip: "t1") == .new && s.mark("eyes", tip: "t1") == .asked, "what still wants Phil is an attention item, not the review's kind")
        #expect(s.mark("asked", tip: "t2") == .moved && s.trusted("asked", tip: "t2") == nil, "a moved tip is stale, never 'same'")
        #expect(s.mark("elsewhere", tip: "t1") == nil, "a branch the review didn't name says nothing")
        #expect(ReviewSince.Mark.same.word == nil && ReviewSince.Mark.new.loud && !ReviewSince.Mark.asked.loud)
    }

    @Test func theLineAndTheFilesAreWhatStillWantsPhil() {
        #expect(ReviewSince.line(Self.entry("asked", eyes: [Self.partly])) == "n6", "a needs-eyes answer is an item's to say")
        #expect(ReviewSince.line(Self.entry("asked")) == "n6" && ReviewSince.line(Self.entry("new", why: "")) == nil, "no answers: the why")
        let asked = Self.entry("asked", notes: [ReviewSince.Note(id: "n6", file: "q.ts", line: 3, said: nil, answers: [Self.liked, Self.done])])
        #expect(ReviewSince.line(asked) == "full id" && ReviewSince.detail(asked) == "done: full id", "changed as asked: what was done, not the note's number")
        #expect(ReviewSince.touched(Self.entry("asked")) == ["a.ts", "b.ts"], "a dropped file isn't in the diff")
        let e = Self.entry("asked", eyes: [Self.partly], notes: [ReviewSince.Note(id: "n7", file: "m/x.ts", line: 1, said: "why ten?", answers: [Self.done, Self.partly, Self.liked])])
        #expect(ReviewSince.answers(e).map(\.answer.id) == ["n7b", "n7d"], "a note that asked nothing has no answer to show")
        #expect(ReviewSince.needsEyes(Self.partly, in: e) && !ReviewSince.needsEyes(Self.done, in: e))
        let item = AttentionItem(id: "a-1", forest: "f", branch: "b", file: "m/x.ts", line: 1, ask: "decide", text: "t", tip: "t1")
        #expect(ReviewSinceView.line(item) == "x.ts:1")
        #expect(ReviewSinceView.said(for: item, in: e) == "why ten?", "his own words at the item's place")
        #expect(ReviewSinceView.said(for: AttentionItem(id: "a-2", forest: "f", branch: "b", file: "other.ts", line: 1, ask: "look", text: "t", tip: "t1"), in: e) == nil)
        #expect(ReviewSinceView.said(for: AttentionItem(id: "a-3", forest: "f", branch: "b", file: "m/x.ts", line: 3, ask: "look", text: "t", tip: "t1"), in: e) == nil,
                "a note on line 1 is not what he said about line 3")
    }

    @Test func theNewestAnsweredReviewOfThatForestInThatRepoIsRead() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("review-since-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        func review(_ name: String, forest: String, repo: String, since: Bool = true, why: String = "x") throws {
            let folder = dir.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(#"{"repo": "\#(repo)"}"#.utf8).write(to: folder.appendingPathComponent("review.json"))
            if since {
                try Data(#"{"forest": "\#(forest)", "branches": {"b": {"kind": "asked", "tipNow": "t", "why": "\#(why)"}}}"#.utf8)
                    .write(to: folder.appendingPathComponent("since.json"))
            }
        }
        try review("2026-11-25T100000-domain-notices", forest: "domain-notices", repo: "loops", why: "older")
        try review("2026-11-25T120000-domain-notices", forest: "domain-notices", repo: "loops", why: "newest answered")
        try review("2026-11-25T130000-domain-notices", forest: "domain-notices", repo: "loops", since: false)
        try review("2026-11-25T140000-domain-notices", forest: "domain-notices", repo: "other")
        let io = ReviewSinceIO(dir: dir)
        #expect(io.latest(repo: "loops", forest: "domain-notices")?.branches["b"]?.why == "newest answered",
                "an unanswered review and another repo's are skipped")
        #expect(io.latest(repo: "loops", forest: "notices") == nil, "a forest whose name ends another's is not that forest")
        #expect(ReviewSinceIO(dir: dir.appendingPathComponent("none")).latest(repo: "loops", forest: "domain-notices") == nil)
    }
}
