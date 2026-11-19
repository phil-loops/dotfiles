import CanopyTestSupport
import CanopyCore
import Foundation
import Testing
@testable import CanopyUI

/// Coming back to a branch whose diff has moved: the diff last read there shows, marked older, while
/// the current one is read; keys that act on its lines wait for the current one, or refuse.
@MainActor @Suite(.serialized) struct StaleDiffTests {
    let base = ReviewPageTests()
    static let a = ReviewPageTests.branch
    static let b = "loops:hankles-next"
    static let reading = "reading the current diff — this key runs when it's in"

    func payload(_ name: String, baseSha: String, b patchB: String? = nil) -> String {
        let files: JSONValue = .array([
            ["path": "a.ts", "add": 3, "del": 2, "patch": .string(ReviewPageTests.patchA)],
            ["path": "b.ts", "add": 1, "del": 1, "patch": .string(patchB ?? ReviewPageTests.patchB)],
        ])
        let o: JSONValue = ["branch": .string(name), "baseSha": .string(baseSha), "files": files]
        return String(decoding: try! JSONEncoder().encode(o), as: UTF8.self)
    }

    func move(_ app: AppModel, _ id: String, to tip: String) throws {
        var branch = try #require(app.store.rawView("branch", id))
        branch["tip"] = .string(tip)
        try ReviewGuideTests().upsert(app, "branch", id, .object(branch))
    }

    func go(_ app: AppModel, _ name: String) {
        app.router.navigate(.review(repo: "loops", branch: name))
        ReviewPageState.of(app).sync()
    }

    /// Answer the held reads of a branch's diff until the page has its current one (a neighbour's
    /// prefetch of an older tip may be held too).
    func answer(_ app: AppModel, _ port: Int, _ name: String, _ body: String) async {
        await until("\(name)'s current diff") {
            HeldLookupStub.release(port, "/loops/node", body, query: "branch=\(name)")
            return ReviewPageState.of(app).diffCurrent
        }
    }

    func posted(_ port: Int, _ path: String = "/loops/viewed") -> Bool { ShipStub.posts(port).contains { $0.path == path } }

    /// A's diff read, a visit to B, A's tip moved meanwhile, back on A with its new diff held.
    func olderA() async throws -> (AppModel, Int, String) {
        let (app, port) = try await base.app(protocolClasses: [HeldLookupStub.self, ShipStub.self])
        let pg = ReviewPageState.of(app)
        let first = try #require(pg.payload?.key)
        go(app, "hankles-next")
        await until("B's diff") { pg.payload?.key.hasPrefix("\(Self.b)@") == true }
        HeldLookupStub.hold(port, "/loops/node")
        try move(app, Self.a, to: "moved-tip")
        go(app, "add-hankles-limited-label")
        await until("A's new diff asked for") { HeldLookupStub.waiting(port, "/loops/node", query: "branch=add-hankles-limited-label") }
        return (app, port, first)
    }

    @Test func theOlderDiffShowsMarkedWhileTheMovedBranchIsRead() async throws {
        let (app, port, first) = try await olderA()
        let pg = ReviewPageState.of(app)
        #expect(pg.payload?.key == first && pg.payload?.key != pg.keyOf)
        #expect(pg.diffHere && pg.diffStale && !pg.diffCurrent)
        #expect(!pg.stops.isEmpty && pg.here?.key == "l|a.ts|R:2")
        app.keys.handle("j")
        #expect(pg.here?.key == "l|a.ts|R:3" && app.runner.held == nil, "reading keys still move through the older diff")
        await answer(app, port, "add-hankles-limited-label", payload("add-hankles-limited-label", baseSha: "fresh"))
        #expect(!pg.diffStale && pg.baseSha == "fresh")
        #expect(pg.here?.key == "l|a.ts|R:3", "the line it was on is in the new diff: the cursor stays on it")
    }

    @Test func aKeyThatActsOnTheLinesWaitsForTheCurrentDiff() async throws {
        let (app, port, _) = try await olderA()
        let pg = ReviewPageState.of(app)
        let ship = ShipState.of(app)
        app.runner.dispatch("review.comment", via: .key)
        #expect(app.runner.held?.id == "review.comment" && app.runner.note == Self.reading && ship.composer == nil)
        await answer(app, port, "add-hankles-limited-label", payload("add-hankles-limited-label", baseSha: "fresh"))
        guard case .line(_, "a.ts", .right, 2, nil, nil)? = ship.composer else { Issue.record("\(String(describing: ship.composer))"); return }
        #expect(pg.diffCurrent && app.runner.held == nil)
    }

    /// A mark is kept by the change's content: one pressed on the older read must never land on
    /// whatever the current read has on that line.
    @Test func aMarkIsNeverReplayedOntoCodeTheReaderDidntSee() async throws {
        let (app, port, _) = try await olderA()
        let pg = ReviewPageState.of(app)
        ShipStub.answer(port, "POST", "/loops/viewed", #"{"ok":true}"#)
        pg.setCursor("l|b.ts|R:6")
        app.runner.dispatch("review.viewed", via: .key)
        #expect(app.runner.held == nil && app.runner.note == "reading the current diff — mark it once it's in")
        app.runner.dispatch("review.flag", via: .key)
        #expect(app.runner.held == nil && app.runner.note == "reading the current diff — flag it once it's in")
        app.runner.dispatch("review.viewed.file", via: .click, arg: "b.ts")
        #expect(app.runner.held == nil && app.runner.note == "reading the current diff — mark the file once it's in")
        let evil = ["@@ -5,2 +5,2 @@", " a", "-b", "+EVIL"].joined(separator: "\n")
        await answer(app, port, "add-hankles-limited-label", payload("add-hankles-limited-label", baseSha: "fresh", b: evil))
        #expect(pg.here?.key == "l|b.ts|R:6")
        #expect(!posted(port), "nothing marked the code that came in")
    }

    @Test func aGapOnTheOlderDiffIsNotRevealedOnTheCurrentOne() async throws {
        let (app, port, _) = try await olderA()
        let pg = ReviewPageState.of(app)
        pg.setCursor("g|a.ts|1")
        app.keys.handle("ret")
        #expect(app.runner.held == nil && app.runner.note == "reading the current diff — show the hidden lines once it's in")
        await answer(app, port, "add-hankles-limited-label", payload("add-hankles-limited-label", baseSha: "fresh"))
        #expect(pg.contextOf("a.ts") == nil)
    }

    @Test func aFailedReadIsSaidAndTheOlderDiffTakesNoKeys() async throws {
        let (app, port, _) = try await olderA()
        let pg = ReviewPageState.of(app)
        app.runner.dispatch("review.comment", via: .key)
        #expect(app.runner.held?.id == "review.comment")
        await until("the failed read") {
            HeldLookupStub.release(port, "/loops/node", "not json", query: "branch=add-hankles-limited-label")
            return pg.loadErr != nil
        }
        #expect(app.runner.held == nil && app.runner.note?.hasPrefix("couldn't read the current diff") == true)
        #expect(pg.diffStale, "still the older diff, still marked so")
        app.runner.dispatch("review.open", via: .key)
        #expect(app.runner.held == nil && app.runner.note?.hasPrefix("couldn't read the current diff") == true)
        #expect(ShipState.of(app).composer == nil)
    }

    @Test func aFailedCommitReadDropsItsHeldKeyAndSaysWhy() async throws {
        let (app, port) = try await base.app(protocolClasses: [HeldLookupStub.self, ShipStub.self])
        let pg = ReviewPageState.of(app)
        HeldLookupStub.hold(port, "/loops/commit-diff")
        pg.setStretch("c2")
        await until("the held commit") { HeldLookupStub.waiting(port, "/loops/commit-diff") }
        app.runner.dispatch("review.findings", via: .key)
        #expect(app.runner.held?.id == "review.findings")
        await until("the failed commit read") {
            HeldLookupStub.release(port, "/loops/commit-diff", "not json")
            return pg.commitErr != nil
        }
        #expect(pg.readErr != nil && app.runner.held == nil && app.runner.note?.hasPrefix("couldn't read the current diff") == true)
        app.runner.dispatch("review.types", via: .key)
        #expect(app.runner.held == nil && app.runner.note?.hasPrefix("couldn't read the current diff") == true)
    }

    @Test func aFirstVisitShowsNoDiffUntilItsOwnIsRead() async throws {
        let (app, port) = try await base.app(protocolClasses: [HeldLookupStub.self, ShipStub.self])
        let pg = ReviewPageState.of(app)
        HeldLookupStub.hold(port, "/loops/node")
        try move(app, Self.b, to: "moved-b")
        go(app, "hankles-next")
        await until("B's diff asked for") { HeldLookupStub.waiting(port, "/loops/node", query: "branch=hankles-next") }
        #expect(pg.payload == nil && !pg.diffHere && !pg.diffStale, "never A's diff, and B has none read yet")
        app.runner.dispatch("review.comment", via: .key)
        #expect(app.runner.held?.id == "review.comment")
        await answer(app, port, "hankles-next", payload("hankles-next", baseSha: "b-base"))
        #expect(pg.payload?.key.hasPrefix("\(Self.b)@") == true && app.runner.held == nil)
        #expect(app.runner.note?.hasPrefix("no PR to comment on yet") == true, "the held key ran (B has no PR to comment on)")
    }

    @Test func anOlderReadIsAlwaysItsOwnBranchs() async throws {
        let (app, port) = try await base.app(protocolClasses: [HeldLookupStub.self, ShipStub.self])
        let pg = ReviewPageState.of(app)
        go(app, "hankles-next")
        await until("B's diff") { pg.payload?.key.hasPrefix("\(Self.b)@") == true }
        go(app, "add-hankles-limited-label")
        await until("A's diff") { pg.diffCurrent && pg.payload?.key.hasPrefix("\(Self.a)@") == true }
        HeldLookupStub.hold(port, "/loops/node")
        try move(app, Self.b, to: "moved-b")
        go(app, "hankles-next")
        #expect(pg.diffStale && pg.payload?.key.hasPrefix("\(Self.b)@") == true)
        try move(app, Self.a, to: "moved-a")
        go(app, "add-hankles-limited-label")
        #expect(pg.diffStale && pg.payload?.key.hasPrefix("\(Self.a)@") == true)
    }

    /// A J/K hop's file lands on the older read, so the current read doesn't move the reader again.
    @Test func aHopLandsOnTheOlderReadAndTheCurrentOneKeepsWhereTheReaderWent() async throws {
        let (app, port) = try await base.app(protocolClasses: [HeldLookupStub.self, ShipStub.self])
        let pg = ReviewPageState.of(app)
        go(app, "hankles-next")
        await until("B's diff") { pg.payload?.key.hasPrefix("\(Self.b)@") == true }
        go(app, "add-hankles-limited-label")
        await until("A's diff") { pg.diffCurrent && pg.payload?.key.hasPrefix("\(Self.a)@") == true }
        HeldLookupStub.hold(port, "/loops/node")
        try move(app, Self.b, to: "moved-b")
        pg.setCursor("l|b.ts|R:6")
        app.keys.handle("J")
        await until("B's older read") { pg.diffStale && pg.payload?.key.hasPrefix("\(Self.b)@") == true }
        #expect(pg.here?.path == "b.ts", "the hop's file, on the read that's up")
        app.keys.handle("k")
        let moved = try #require(pg.here?.key)
        #expect(moved != "l|b.ts|R:6")
        await answer(app, port, "hankles-next", payload("hankles-next", baseSha: "b-base"))
        #expect(pg.here?.key == moved)
    }

    @Test func aCommentStartedBeforeTheBranchMovedNeitherPostsNorQuotesOldLines() async throws {
        let (app, port) = try await base.app(protocolClasses: [HeldLookupStub.self, ShipStub.self])
        let pg = ReviewPageState.of(app)
        let ship = ShipState.of(app)
        ShipStub.answer(port, "POST", "/loops/review-draft", #"{"ok":true}"#)
        app.runner.dispatch("review.comment", via: .key)
        let c = try #require(ship.composer)
        ship.setText(c.key, "words")
        app.keys.handle("esc")
        HeldLookupStub.hold(port, "/loops/node")
        try move(app, Self.a, to: "moved-tip")
        pg.sync()
        #expect(pg.diffStale)
        for id in ["review.compose.draft", "review.compose.suggest"] {
            app.runner.dispatch(id, via: .key)
            #expect(app.runner.note == "reading the current diff — this comment waits for it", "\(id)")
        }
        #expect(ship.text(c.key) == "words")
        await answer(app, port, "add-hankles-limited-label", payload("add-hankles-limited-label", baseSha: "fresh"))
        app.runner.dispatch("review.compose.draft", via: .key)
        #expect(app.runner.note?.hasPrefix("this comment's line changed since it was started") == true)
        #expect(!posted(port, "/loops/review-draft"))
        app.runner.dispatch("review.comment", via: .key)
        #expect(ship.composer == c && ship.text(c.key) == "words", "the line again brings the words back")
        app.keys.handle("esc")
        app.runner.dispatch("review.compose.draft", via: .key)
        await until("the draft, on the current read") { posted(port, "/loops/review-draft") }
    }

    func visitBThenA(_ app: AppModel) async {
        let pg = ReviewPageState.of(app)
        go(app, "hankles-next")
        await until("B's diff") { pg.payload?.key.hasPrefix("\(Self.b)@") == true }
        go(app, "add-hankles-limited-label")
        await until("A's diff") { pg.diffCurrent && pg.payload?.key.hasPrefix("\(Self.a)@") == true }
    }

    /// The page arrives while a prefetch of its current diff is in flight, so it reads nothing itself:
    /// that prefetch failing must say so, not leave the older read up and a held key waiting forever.
    @Test func aFailedPrefetchOfTheCurrentDiffSaysSoInsteadOfWaiting() async throws {
        let (app, port) = try await base.app(protocolClasses: [HeldLookupStub.self, ShipStub.self])
        let pg = ReviewPageState.of(app)
        await visitBThenA(app)
        HeldLookupStub.hold(port, "/loops/node")
        try move(app, Self.b, to: "moved-b")
        pg.warm(try #require(app.store.view(Branch.self, Self.b)))
        await until("the prefetch") { HeldLookupStub.waiting(port, "/loops/node", query: "branch=hankles-next") }
        go(app, "hankles-next")
        #expect(pg.diffStale)
        app.runner.dispatch("review.comment", via: .key)
        #expect(app.runner.held?.id == "review.comment")
        await until("the failed prefetch") {
            HeldLookupStub.release(port, "/loops/node", "not json", query: "branch=hankles-next")
            return pg.loadErr != nil
        }
        #expect(app.runner.held == nil && app.runner.note?.hasPrefix("couldn't read the current diff") == true)
    }

    /// The usual J/K: the neighbour's current diff is already prefetched, so no older read goes up and
    /// the hop lands on its file's first change in the current diff.
    @Test func aHopOntoAPrefetchedCurrentDiffLandsOnItsFilesFirstChange() async throws {
        let (app, port) = try await base.app()
        let pg = ReviewPageState.of(app)
        await visitBThenA(app)
        let moved = ["@@ -9,2 +9,2 @@", " a", "-b", "+B"].joined(separator: "\n")
        ShipStub.answer(port, "GET", "/loops/node", payload("hankles-next", baseSha: "b-base", b: moved))
        try move(app, Self.b, to: "moved-b")
        let moving = try #require(app.store.view(Branch.self, Self.b))
        pg.warm(moving)
        await until("the prefetch") { pg.isCached(ReviewPageState.diffKey(id: Self.b, at: "moved-b", ref: "", parent: moving.parent, stamp: moving.readStamp ?? "")) }
        pg.setCursor("l|b.ts|R:6")
        app.keys.handle("J")
        await until("B's current diff") { pg.diffCurrent && pg.payload?.key.hasPrefix("\(Self.b)@") == true }
        #expect(pg.here?.key == "l|b.ts|R:10")
    }

    /// A comment's line is fixed by the tip on the new side, by the tip and the base on the old.
    @Test(arguments: [Side.right, .left]) func aBaseSwitchKeepsANewSideCommentButNotAnOldSideOne(_ side: Side) async throws {
        let (app, port) = try await base.app()
        let pg = ReviewPageState.of(app)
        let ship = ShipState.of(app)
        ShipStub.answer(port, "POST", "/loops/review-draft", #"{"ok":true}"#)
        pg.column = side
        app.runner.dispatch("review.comment", via: .key)
        let c = try #require(ship.composer)
        guard case .line(_, "a.ts", side, 2, nil, nil) = c else { Issue.record("\(c)"); return }
        ship.setText(c.key, "words")
        app.keys.handle("esc")
        ShipStub.answer(port, "GET", "/loops/node", payload("add-hankles-limited-label", baseSha: "main-base"))
        pg.setBase(.main)
        await until("the diff against main") { pg.diffCurrent && pg.baseSha == "main-base" }
        app.runner.dispatch("review.compose.draft", via: .key)
        if side == .right {
            await until("the draft") { posted(port, "/loops/review-draft") }
        } else {
            #expect(app.runner.note?.hasPrefix("this comment's line changed since it was started") == true)
            #expect(!posted(port, "/loops/review-draft"))
        }
    }

    @Test func aFailedBranchReadLeavesAKeyHeldForTheCommitRead() async throws {
        let (app, port) = try await base.app(protocolClasses: [HeldLookupStub.self, ShipStub.self])
        let pg = ReviewPageState.of(app)
        HeldLookupStub.hold(port, "/loops/commit-diff")
        pg.setStretch("c2")
        await until("the held commit") { HeldLookupStub.waiting(port, "/loops/commit-diff") }
        app.runner.dispatch("review.findings", via: .key)
        #expect(app.runner.held?.id == "review.findings")
        ShipStub.answer(port, "GET", "/loops/node", "not json")
        try move(app, Self.a, to: "moved-tip")
        pg.sync()
        await until("the failed branch read") { pg.loadErr != nil }
        #expect(app.runner.held?.id == "review.findings", "it waits on the commit's read, not the branch's")
    }

    /// A place copied or split from the older read would pair its line numbers with the new tip.
    @Test func anOlderReadsLineIsNeverPairedWithTheNewTip() async throws {
        let (app, _, _) = try await olderA()
        let pg = ReviewPageState.of(app)
        pg.setCursor("l|b.ts|R:6")
        #expect(pg.herePlace() == nil)
        let windows = pg.windows.count
        app.runner.dispatch("review.window.right", via: .key)
        #expect(app.runner.note == "nothing to copy here" && pg.windows.count == windows)
        let link = app.here().shared.link
        #expect(!link.contains("moved-tip") && !link.contains("line="), "\(link)")
    }

    /// The read that failed was an older key's: a newer one already in flight is what the page waits on.
    @Test func anOlderFailureDoesNotOutliveANewerReadInFlight() async throws {
        let (app, port, _) = try await olderA()
        let pg = ReviewPageState.of(app)
        await until("the failed read") {
            HeldLookupStub.release(port, "/loops/node", "not json", query: "branch=add-hankles-limited-label")
            return pg.loadErr != nil
        }
        var newer = try #require(app.store.view(Branch.self, Self.a)); newer.tip = "tip3"
        pg.warm(newer)
        await until("the newer read") { HeldLookupStub.waiting(port, "/loops/node", query: "branch=add-hankles-limited-label") }
        try move(app, Self.a, to: "tip3")
        pg.sync()
        #expect(pg.loadErr == nil)
        app.runner.dispatch("review.comment", via: .key)
        #expect(app.runner.held?.id == "review.comment" && app.runner.note == Self.reading)
    }

    /// A flag found on the older read lands again on the current one by its block — the same code,
    /// wherever lines inserted above it moved it.
    @Test func aFlagOnTheOlderReadLandsOnItsBlockInTheCurrentOne() async throws {
        let (app, port, _) = try await olderA()
        let pg = ReviewPageState.of(app)
        let block = try #require(pg.fileOf("b.ts")?.blocks.first?.key)
        let flag = try JSONDecoder().decode(Flag.self, from: Data(#"{"key":"\#(block)","at":1,"path":"b.ts","line":6,"text":"B"}"#.utf8))
        pg.land(flag: flag)
        #expect(pg.here?.key == "l|b.ts|R:6")
        let shifted = ["@@ -5,2 +8,2 @@", " a", "-b", "+B"].joined(separator: "\n")
        await answer(app, port, "add-hankles-limited-label", payload("add-hankles-limited-label", baseSha: "fresh", b: shifted))
        #expect(pg.here?.key == "l|b.ts|R:9")
    }

    @Test func aFlagOnTheOlderReadLeavesTheReaderWhereTheyMovedTo() async throws {
        let (app, port, _) = try await olderA()
        let pg = ReviewPageState.of(app)
        let block = try #require(pg.fileOf("b.ts")?.blocks.first?.key)
        let flag = try JSONDecoder().decode(Flag.self, from: Data(#"{"key":"\#(block)","at":1,"path":"b.ts","line":6,"text":"B"}"#.utf8))
        pg.land(flag: flag)
        #expect(pg.here?.key == "l|b.ts|R:6")
        app.keys.handle("k")
        let moved = try #require(pg.here?.key)
        #expect(moved != "l|b.ts|R:6")
        let shifted = ["@@ -5,2 +8,2 @@", " a", "-b", "+B"].joined(separator: "\n")
        await answer(app, port, "add-hankles-limited-label", payload("add-hankles-limited-label", baseSha: "fresh", b: shifted))
        #expect(pg.here?.key != "l|b.ts|R:9", "the current read doesn't pull the reader back to the flag")
        #expect(pg.pendingFlag == nil && pg.flagShownAt == nil)
    }

    @Test func forgettingTheDiffsForgetsTheOlderRead() async throws {
        let (app, _, _) = try await olderA()
        let pg = ReviewPageState.of(app)
        pg.forgetDiffs()
        #expect(pg.payload == nil && !pg.diffStale)
        go(app, "hankles-next")
        go(app, "add-hankles-limited-label")
        #expect(pg.payload == nil && !pg.diffHere, "no read from before the repo list moved comes back")
    }

    @Test func theDiffCacheKeepsABoundedFewAndRetiresAnOlderTip() async throws {
        let (app, port, first) = try await olderA()
        let pg = ReviewPageState.of(app)
        await answer(app, port, "add-hankles-limited-label", payload("add-hankles-limited-label", baseSha: "fresh"))
        #expect(!pg.isCached(first), "A's older tip goes once its newer read is in")
        let data = try #require(pg.payload?.data)
        let current = pg.keyOf
        for i in 0..<(ReviewPageState.cacheLimit * 2) { pg.land("other@\(i)", data) }
        #expect(pg.cachedCount == ReviewPageState.cacheLimit)
        #expect(pg.isCached(current), "a branch's last read outlasts the rest")
    }

    @Test func theCursorKeepsItsFileAndNearestLineWhenTheCurrentDiffLands() async throws {
        let (app, port, _) = try await olderA()
        let pg = ReviewPageState.of(app)
        pg.setCursor("l|b.ts|R:6")
        #expect(pg.here?.key == "l|b.ts|R:6")
        let moved = ["@@ -9,2 +9,2 @@", " a", "-b", "+B"].joined(separator: "\n")
        await answer(app, port, "add-hankles-limited-label", payload("add-hankles-limited-label", baseSha: "fresh", b: moved))
        #expect(pg.here?.key == "l|b.ts|R:9", "its line left the diff: the nearest line of the same file, not whatever row took its place")
    }

    /// Both directions: every key the rule names exists, and every command the review page registers —
    /// local, write, task or route, on its scopes or named `review.` anywhere — is either under the rule
    /// or says why it needs none.
    @Test func everyReviewPageCommandIsUnderTheRuleOrSaysWhyNot() async throws {
        let (app, _) = try await base.app()
        let named = ReviewPageState.actsOnDiff.union(ReviewPageState.actsOnItsOwn.keys)
        #expect(ReviewPageState.actsOnDiff.isDisjoint(with: ReviewPageState.actsOnItsOwn.keys))
        for id in named { #expect(app.registry.command(id) != nil, "\(id) is named but not registered") }
        let scopes: Set<Scope> = [.review, .line, .gap, .thread, .pending]
        for id in app.registry.order {
            guard let c = app.registry.command(id), scopes.contains(c.scope) || id.hasPrefix("review.") else { continue }
            #expect(named.contains(id), "\(id): put it under the rule (actsOnDiff) or say why not (actsOnItsOwn)")
        }
    }
}
