import CanopyCore
import Foundation
import Testing
@testable import CanopyUI

@MainActor @Suite(.serialized) struct ReviewFindingTests {
    let reply = #"{"flags":[{"path":"b.ts","line":6,"text":"check this change"}]}"#

    func app() async throws -> (AppModel, Int) {
        try await ReviewPageTests().app(protocolClasses: [HeldLookupStub.self, ShipStub.self])
    }

    func loaded(_ app: AppModel) -> Bool {
        ReviewFlags.of(app).cached(app, ReviewPageState.Target(repo: "loops", name: "add-hankles-limited-label", id: ReviewPageTests.branch)) != nil
    }

    @Test func findingMotionsRecomputeTheirStartingOrdinalAfterOtherFilesFold() async throws {
        let payload = ReviewProbeTests().payload([("a.ts", ReviewPageTests.patchA), ("b.ts", ReviewPageTests.patchA)])
        let (app, port) = try await ReviewPageTests().app(payload, protocolClasses: [HeldLookupStub.self, ShipStub.self])
        let pg = ReviewPageState.of(app)
        pg.goTo(file: "b.ts")
        HeldLookupStub.hold(port, "/loops/review-flags")
        app.runner.dispatch("review.finding.next", via: .key)
        await until("the pending motion") { HeldLookupStub.waiting(port, "/loops/review-flags") }
        for block in try #require(pg.fileOf("a.ts")).blocks { pg.viewedOverride[block.key] = .viewed }
        HeldLookupStub.release(port, "/loops/review-flags", #"{"flags":[{"path":"b.ts","line":22,"text":"later finding"}]}"#)
        await until("the findings cached") { loaded(app) }
        #expect(pg.here?.key == "l|b.ts|R:22")
    }

    @Test func leavingSelectModeCancelsThePendingFindingMotion() async throws {
        let (app, port) = try await app()
        HeldLookupStub.hold(port, "/loops/review-flags")
        app.keys.handle("v")
        app.runner.dispatch("review.finding.next", via: .key)
        await until("the select motion") { HeldLookupStub.waiting(port, "/loops/review-flags") }
        let cursor = ReviewPageState.of(app).here?.key
        app.keys.handle("esc")
        HeldLookupStub.release(port, "/loops/review-flags", reply)
        await until("the cancelled motion cached") { loaded(app) }
        #expect(app.keys.mode == .normal && ReviewPageState.of(app).here?.key == cursor && CodeLookup.of(app).pop == nil)
    }

    @Test func emptyFindingsClearTheHoverTheySuperseded() async throws {
        let (app, port) = try await app()
        HeldLookupStub.hold(port, "/loops/lsp/hover")
        let task = try #require(CodeLookup.of(app).hover(CodeLookup.Position(path: "a.ts", line: 2, character: 0), .branch(repo: "loops", name: "add-hankles-limited-label", base: nil)))
        await until("the older hover") { HeldLookupStub.waiting(port, "/loops/lsp/hover") }
        ShipStub.answer(port, "GET", "/loops/review-flags", #"{"flags":[]}"#)
        app.runner.dispatch("review.findings", via: .key)
        await until("the empty findings") { app.runner.note == "push-ready's review found nothing here" }
        #expect(CodeLookup.of(app).pop == nil && app.nav.picker == nil)
        HeldLookupStub.release(port, "/loops/lsp/hover", #"{"ok":true,"contents":"obsolete hover"}"#)
        await task.value
        #expect(CodeLookup.of(app).pop == nil)
    }

    @Test(arguments: [200, 404]) func missingFlagsAreAReadFailureRatherThanAMissingReview(_ status: Int) async throws {
        let (app, port) = try await app()
        ShipStub.answer(port, "GET", "/loops/review-flags", "{}", status: status)
        app.runner.dispatch("review.findings", via: .key)
        await until("the read refusal") { app.runner.note == "couldn't read the review findings · try again" }
        #expect(!loaded(app) && CodeLookup.of(app).pop == nil && app.nav.picker == nil)
    }

    @Test func navigationBeforeTheTaskStartsSendsNoRequest() async throws {
        let (app, port) = try await app()
        app.runner.dispatch("review.findings", via: .key)
        app.router.navigate(.review(repo: "loops", branch: "hankles-next"))
        await Task.yield()
        #expect(!ShipStub.lock.withLock { (ShipStub.seen["\(port)"] ?? []).contains { $0.path == "/loops/review-flags" } })
        #expect(app.nav.picker == nil)
    }

    @Test(arguments: ["review.findings", "review.finding.next"]) func leavingTheBranchDiscardsTheReaderEffect(_ command: String) async throws {
        let (app, port) = try await app()
        HeldLookupStub.hold(port, "/loops/review-flags")
        app.runner.dispatch(command, via: .key)
        await until("the held findings") { HeldLookupStub.waiting(port, "/loops/review-flags") }
        app.router.navigate(.review(repo: "loops", branch: "hankles-next"))
        ReviewPageState.of(app).sync()
        await until("the destination branch") { ReviewPageState.of(app).payload?.key.hasPrefix("loops:hankles-next@") == true }
        let cursor = ReviewPageState.of(app).here?.key
        HeldLookupStub.release(port, "/loops/review-flags", reply)
        await until("the origin cache") { loaded(app) }
        #expect(app.nav.picker == nil && ReviewPageState.of(app).here?.key == cursor)
        #expect(app.router.route == .review(repo: "loops", branch: "hankles-next"))
    }

    @Test func escapeCancelsPendingFindings() async throws {
        let (app, port) = try await app()
        HeldLookupStub.hold(port, "/loops/review-flags")
        app.runner.dispatch("review.findings", via: .key)
        await until("the pending findings") { HeldLookupStub.waiting(port, "/loops/review-flags") }
        #expect(CodeLookup.of(app).pop?.isWait == true)
        app.keys.handle("esc")
        HeldLookupStub.release(port, "/loops/review-flags", reply)
        await until("the cancelled read cached") { loaded(app) }
        #expect(app.nav.picker == nil && CodeLookup.of(app).pop == nil)
    }

    @Test func aNewerPickerSurvivesAnOlderFindingsReply() async throws {
        let (app, port) = try await app()
        HeldLookupStub.hold(port, "/loops/review-flags")
        app.runner.dispatch("review.findings", via: .key)
        await until("the pending findings") { HeldLookupStub.waiting(port, "/loops/review-flags") }
        app.nav.pick("newer picker", [PickItem(label: "keep this")])
        HeldLookupStub.release(port, "/loops/review-flags", reply)
        await until("the findings cached") { loaded(app) }
        #expect(app.nav.picker?.title == "newer picker" && app.nav.picker?.items.map(\.label) == ["keep this"])
    }

    @Test func aNewerCodeLookupCancelsFindingNavigation() async throws {
        let (app, port) = try await app()
        HeldLookupStub.hold(port, "/loops/review-flags")
        HeldLookupStub.hold(port, "/loops/lsp/hover")
        app.runner.dispatch("review.finding.next", via: .key)
        await until("the pending finding motion") { HeldLookupStub.waiting(port, "/loops/review-flags") }
        let pg = ReviewPageState.of(app)
        let cursor = pg.here?.key
        let task = try #require(CodeLookup.of(app).hover(CodeLookup.Position(path: "a.ts", line: 2, character: 0), .branch(repo: "loops", name: "add-hankles-limited-label", base: nil)))
        await until("the newer hover") { HeldLookupStub.waiting(port, "/loops/lsp/hover") }
        HeldLookupStub.release(port, "/loops/review-flags", reply)
        await until("the findings cached") { loaded(app) }
        #expect(pg.here?.key == cursor && app.nav.picker == nil)
        HeldLookupStub.release(port, "/loops/lsp/hover", #"{"ok":true,"contents":"newer hover"}"#)
        await task.value
        #expect(CodeLookup.of(app).pop?.text == "newer hover")
    }

    @Test func emptyFindingsReplaceThePreviousHoverPresentation() async throws {
        let (app, port) = try await app()
        HeldLookupStub.hold(port, "/loops/lsp/hover")
        let task = try #require(CodeLookup.of(app).hover(CodeLookup.Position(path: "a.ts", line: 2, character: 0), .branch(repo: "loops", name: "add-hankles-limited-label", base: nil)))
        await until("the hover") { HeldLookupStub.waiting(port, "/loops/lsp/hover") }
        ShipStub.answer(port, "GET", "/loops/review-flags", #"{"flags":[]}"#)
        app.runner.dispatch("review.findings", via: .key)
        await until("the empty findings") { app.runner.note == "push-ready's review found nothing here" }
        #expect(CodeLookup.of(app).pop == nil)
        HeldLookupStub.release(port, "/loops/lsp/hover", #"{"ok":true,"contents":"obsolete hover"}"#)
        await task.value
        #expect(CodeLookup.of(app).pop == nil && app.nav.picker == nil)
    }

    @Test func aReadFailureDoesNotClaimThatNoReviewRan() async throws {
        let (app, _) = try await app()
        app.runner.dispatch("review.findings", via: .key)
        await until("the read error") { app.runner.note == "couldn't read the review findings · try again" }
        #expect(CodeLookup.of(app).pop == nil && !loaded(app))
    }

    @Test func anOldPickerCannotReplayPositionsAfterAScopeChange() async throws {
        let (app, port) = try await app()
        let pg = ReviewPageState.of(app)
        ShipStub.answer(port, "GET", "/loops/review-flags", reply)
        app.runner.dispatch("review.findings", via: .key)
        await until("the findings picker") { app.nav.picker != nil }
        app.nav.close()
        ShipStub.answer(port, "GET", "/loops/commit-diff", ReviewPageTests.payload)
        pg.setStretch("older-commit")
        await until("the older scope") { pg.commitFiles?.sha == "older-commit" }
        let cursor = pg.here?.key
        app.nav.reopen()
        app.nav.choose()
        #expect(pg.here?.key == cursor && app.runner.note == "the diff changed · open the findings again")
    }

    @Test func pickerDestinationsAreRecomputedAfterOtherFilesFold() async throws {
        let (app, port) = try await app()
        let pg = ReviewPageState.of(app)
        ShipStub.answer(port, "GET", "/loops/review-flags", reply)
        app.runner.dispatch("review.findings", via: .key)
        await until("the picker") { app.nav.picker != nil }
        for block in try #require(pg.fileOf("a.ts")).blocks { pg.viewedOverride[block.key] = .viewed }
        app.nav.choose()
        #expect(pg.here?.key == "l|b.ts|R:6" && app.runner.note == "check this change")
    }

    @Test func findingsOnlyNavigateSourcesEndingAtTheirBranchTip() async throws {
        let (app, port) = try await app()
        let pg = ReviewPageState.of(app)
        ShipStub.answer(port, "GET", "/loops/review-flags", reply)
        ShipStub.answer(port, "GET", "/loops/commit-diff", ReviewPageTests.payload)
        pg.setStretch("older-commit")
        await until("the older scope") { pg.commitFiles?.sha == "older-commit" }
        let cursor = pg.here?.key
        app.runner.dispatch("review.findings", via: .key)
        await until("the older-source list") { app.nav.picker != nil }
        app.nav.choose()
        #expect(pg.here?.key == cursor && app.runner.note?.hasPrefix("findings belong to the branch tip") == true)
        pg.setStretch(pg.tip)
        await until("the tip-ending scope") { pg.commitFiles?.sha == pg.tip }
        app.runner.dispatch("review.findings", via: .key)
        app.nav.choose()
        #expect(pg.here?.key == "l|b.ts|R:6")
    }

    @Test func aTipRoundTripInvalidatesAnInflightCacheRead() async throws {
        let (app, port) = try await app()
        let flags = ReviewFlags.of(app)
        let target = try #require(ReviewPageState.of(app).target)
        HeldLookupStub.hold(port, "/loops/review-flags")
        let task = Task { try await flags.load(app, target) }
        await until("the source read") { HeldLookupStub.waiting(port, "/loops/review-flags") }
        var branch = try #require(app.store.rawView("branch", target.id))
        let original = branch["tip"]
        branch["tip"] = "other-tip"
        try ReviewGuideTests().upsert(app, "branch", target.id, .object(branch))
        branch["tip"] = original
        try ReviewGuideTests().upsert(app, "branch", target.id, .object(branch))
        HeldLookupStub.release(port, "/loops/review-flags", reply)
        let result = try await task.value
        #expect(result == nil && flags.cached(app, target) == nil)
    }
}
