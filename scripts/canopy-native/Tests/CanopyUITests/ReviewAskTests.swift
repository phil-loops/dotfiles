import CanopyCore
import CanopyTestSupport
import Foundation
import Testing
@testable import CanopyUI

/// space a / space A (srv/asks.py): an ask names the branch and the exact code on screen — the tip and
/// base the diff was read at — and a line ask the place under the cursor; the status line says what
/// happened to the chat.
extension ReviewPageTests {
    @Test func spaceAAsksAboutTheChangeShown() async throws {
        let (a, p) = try await app()
        let pg = ReviewPageState.of(a)
        ShipStub.answer(p, "POST", "/loops/ask", #"{"ok":true,"session":"s1","reused":false,"kind":"brief"}"#)
        keys(a, "space", "a")
        await until("the ask") { ShipStub.posts(p).contains { $0.path == "/loops/ask" } }
        let body = ShipStub.posts(p).last { $0.path == "/loops/ask" }!.body
        #expect(body["kind"] == .string("brief") && body["branch"] == .string("add-hankles-limited-label"), "\(body)")
        #expect(body["sha"] == .string(pg.tip) && body["base"] == .string(pg.baseSha) && !pg.tip.isEmpty, "\(body)")
        await until("the status line") { a.runner.note?.contains("its chat is answering") == true }
    }

    @Test func shiftSpaceAAsksAboutTheLineUnderTheCursor() async throws {
        let (a, p) = try await app()
        ShipStub.answer(p, "POST", "/loops/ask", #"{"ok":true,"session":"s1","reused":true,"kind":"line"}"#)
        keys(a, "w")
        let range = try #require(ReviewPageState.of(a).range)
        keys(a, "space", "A")
        await until("the line ask") { ShipStub.posts(p).contains { $0.path == "/loops/ask" } }
        let body = ShipStub.posts(p).last { $0.path == "/loops/ask" }!.body
        #expect(body["kind"] == .string("line") && body["path"] == .string(range.path), "\(body)")
        #expect(body["line"] == .number(Double(range.line)) && body["side"] == .string(range.side.rawValue), "\(body)")
        await until("the status line") { a.runner.note?.contains("finish the question there") == true }
    }

    @Test func aLineAskOffCodeRefusesBeforeAsking() async throws {
        let (a, p) = try await app()
        let pg = ReviewPageState.of(a)
        pg.setCursor("f|a.ts")
        #expect(pg.range == nil)
        keys(a, "space", "A")
        await until("the refusal") { a.runner.note?.contains("put the cursor on a line of code") == true }
        #expect(!ShipStub.posts(p).contains { $0.path == "/loops/ask" })
    }

    /// One commit on screen isn't the whole change: an ask would name code Phil isn't reading.
    @Test func anAskFromACommitViewRefuses() async throws {
        let (a, p) = try await app()
        let pg = ReviewPageState.of(a)
        ShipStub.answer(p, "GET", "/loops/commit-diff", #"{"sha":"c1","files":[{"path":"c.ts","add":2,"del":0,"patch":"@@ -1,0 +1,2 @@\n+hi\n+there"}]}"#)
        ShipState.of(a).showCommit("c1")
        await until("the commit's diff") { pg.files.map(\.path) == ["c.ts"] }
        a.focus(pane: reviewDiffPane)
        keys(a, "space", "a")
        await until("the refusal") { a.runner.note?.contains("leave the commit view") == true }
        #expect(!ShipStub.posts(p).contains { $0.path == "/loops/ask" })
    }

    @Test func aRefusedAskSaysWhy() async throws {
        let (a, p) = try await app()
        ShipStub.answer(p, "POST", "/loops/ask", #"{"ok":false,"err":"add-hankles-limited-label moved since this diff was read · reload it, then ask"}"#)
        keys(a, "space", "a")
        await until("the refusal") { a.runner.note?.contains("moved since this diff was read") == true }
    }

    /// The page's one gate holds them while an older read of the diff shows (its own tests cover the
    /// hold), so the tip an ask names is the one on screen.
    @Test func asksWaitForTheDiffOnScreenToBeCurrent() {
        #expect(ReviewPageState.actsOnDiff.isSuperset(of: ["review.ask", "review.ask.line"]))
    }

    @Test func theStatusLineSaysWhatHappenedToTheChat() {
        #expect(ReviewAsk.said(["starting": true, "kind": "brief"])?.contains("starting") == true)
        #expect(ReviewAsk.said(["reused": true, "kind": "brief"]) == "its chat is in front")
        #expect(ReviewAsk.said(["reused": true, "moved": true, "kind": "brief"])?.contains("branch moved") == true)
        #expect(ReviewAsk.said(["reused": false, "kind": "brief", "forwardErr": "no pane"])?.hasSuffix("couldn't bring it forward: no pane") == true)
    }
}
