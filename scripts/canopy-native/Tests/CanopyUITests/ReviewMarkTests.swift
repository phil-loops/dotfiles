import CanopyTestSupport
import CanopyCore
import Foundation
import Testing
@testable import CanopyUI

@MainActor @Suite(.serialized) struct ReviewMarkTests {
    @Test func confirmedAncestorsDoNotMaskNewerCanonicalMarks() async throws {
        let (app, _) = try await ReviewPageTests().app()
        let state = ReviewMarks.of(app)
        let older = state.apply("loops", ["key": .flagged])
        let newer = state.apply("loops", ["key": .unread])
        try ReviewGuideTests().upsert(app, "viewed", ReviewPageTests.branch,
                                     ["id": .string(ReviewPageTests.branch), "repo": "loops", "branch": "add-hankles-limited-label", "keys": [], "flagged": ["key"]])
        state.accept(older)
        let value: JSONValue = ["id": .string(ReviewPageTests.branch), "repo": "loops", "branch": "add-hankles-limited-label", "keys": ["key"], "flagged": []]
        let patch: JSONValue = ["domain": "review", "version": .number(Double((app.store.versions["review"] ?? 0) + 1)), "asOf": 100,
                                "upserts": ["viewed": .object([ReviewPageTests.branch: value])]]
        app.store.applyPatch(try Patch.decode(JSONEncoder().encode(patch)))
        state.rollback(newer)
        #expect(state.overrides("loops")["key"] == nil)
        #expect(state.serverMark("loops", "key") == .viewed)
    }

    @Test func threeOverlappingWritesProjectTheLatestNonfailedIntentInEveryOrder() async throws {
        let (app, _) = try await ReviewPageTests().app()
        let state = ReviewMarks.of(app)
        let marks: [Mark] = [.unread, .viewed, .flagged]
        let orders = [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]]
        for first in marks { for second in marks { for third in marks {
            let wants = [first, second, third]
            for failures in 0..<8 { for order in orders {
                state.replace("cases", with: [:])
                let receipts = wants.map { state.apply("cases", ["scenario": $0]) }
                var failed = Set<Int>()
                for index in order {
                    if failures & (1 << index) != 0 { failed.insert(index); state.rollback(receipts[index]) }
                    else { state.accept(receipts[index]) }
                    let expected = (0..<3).last { !failed.contains($0) }.map { wants[$0] } ?? .unread
                    #expect((state.overrides("cases")["scenario"] ?? .unread) == expected,
                            "\(wants), failed \(failures), order \(order), delivered \(index)")
                }
            } }
        } } }
    }

    @Test func failureRollsBackOnlyItsRepositoryAndUntouchedKeys() async throws {
        let (app, _) = try await ReviewPageTests().app()
        let pg = ReviewPageState.of(app)
        let state = ReviewMarks.of(app)
        let write = try #require(DiffCommands.markSet(app, pg, (["first": .flagged, "second": .viewed], ["first": .unread, "second": .unread])))
        _ = state.apply("loops", ["second": .flagged, "newer": .viewed])
        app.router.navigate(.review(repo: "monotoad", branch: "another-branch"))
        pg.sync()
        pg.viewedOverride["other-repo"] = .flagged
        write.rollback?()
        #expect(pg.viewedOverride == ["other-repo": .flagged])
        #expect(state.overrides("loops") == ["second": .flagged, "newer": .viewed])
    }

    @Test(arguments: [true, false]) func twoFailedWritesCannotRestoreEachOther(_ olderFailsFirst: Bool) async throws {
        let (app, _) = try await ReviewPageTests().app()
        let state = ReviewMarks.of(app)
        let older = state.apply("loops", ["key": .flagged])
        let newer = state.apply("loops", ["key": .unread])
        if olderFailsFirst {
            state.rollback(older)
            #expect(state.overrides("loops")["key"] == .unread)
            state.rollback(newer)
        } else {
            state.rollback(newer)
            #expect(state.overrides("loops")["key"] == .flagged)
            state.rollback(older)
        }
        #expect(state.overrides("loops")["key"] == nil)
    }

    @Test func anOlderFailureCannotEraseTheSameNewerMark() async throws {
        let (app, _) = try await ReviewPageTests().app()
        let state = ReviewMarks.of(app)
        let older = state.apply("loops", ["key": .flagged])
        let newer = state.apply("loops", ["key": .flagged])
        state.rollback(older)
        #expect(state.overrides("loops")["key"] == .flagged)
        state.rollback(newer)
        #expect(state.overrides("loops")["key"] == nil)
    }

    @Test func aSuccessfulOlderWriteIsRestoredWhenOnlyTheNewerWriteFails() async throws {
        let (app, _) = try await ReviewPageTests().app()
        let state = ReviewMarks.of(app)
        let older = state.apply("loops", ["key": .flagged])
        let newer = state.apply("loops", ["key": .unread])
        state.accept(older)
        state.rollback(newer)
        #expect(state.overrides("loops")["key"] == .flagged)
    }

    @Test func pendingWritesDoNotRetireAgainstAnOlderEqualServerValue() async throws {
        let (app, _) = try await ReviewPageTests().app()
        let state = ReviewMarks.of(app)
        let older = state.apply("loops", ["key": .flagged])
        let newer = state.apply("loops", ["key": .unread])
        let patch: JSONValue = ["domain": "review", "version": .number(Double((app.store.versions["review"] ?? 0) + 1)), "upserts": [:]]
        app.store.applyPatch(try Patch.decode(JSONEncoder().encode(patch)))
        #expect(state.overrides("loops")["key"] == .unread)
        state.rollback(older)
        state.rollback(newer)
        #expect(state.overrides("loops")["key"] == nil)
    }

    @Test func flagUndoKeepsItsSubjectAndLocationAfterNavigation() async throws {
        let (app, _) = try await ReviewPageTests().app()
        let pg = ReviewPageState.of(app)
        let view = try #require(pg.views.first)
        let block = try #require(view.blocks.first)
        pg.viewedOverride[block.key] = .flagged
        let original = try #require(DiffCommands.markSet(app, pg, ([block.key: .unread], [block.key: .flagged])))
        app.router.navigate(.review(repo: "monotoad", branch: "another-branch"))
        pg.sync()
        pg.viewedOverride["another"] = .viewed
        let inverse = try #require(original.inverse?([:]))
        #expect(inverse.target == ReviewPageTests.branch)
        let command = try #require(app.registry.command(inverse.id)?.write)
        let undo = try #require(try command(inverse.target, inverse.arg))
        #expect(undo.path == "/loops/viewed" && undo.body["branch"]?.string == "add-hankles-limited-label")
        #expect(undo.body["marks"] == .object([block.key: "flagged"]))
        #expect(undo.body["where"]?[block.key]?["path"]?.string == view.file.path)
        #expect(pg.viewedOverride == ["another": .viewed])
        #expect(ReviewMarks.of(app).overrides("loops")[block.key] == .flagged)
    }

    @Test func settlementReadsTheOriginatingRepository() async throws {
        let (app, _) = try await ReviewPageTests().app()
        let pg = ReviewPageState.of(app)
        let write = try #require(DiffCommands.markSet(app, pg, (["key": .viewed], ["key": .unread])))
        app.router.navigate(.review(repo: "monotoad", branch: "another-branch"))
        pg.sync()
        try ReviewGuideTests().upsert(app, "viewed", "monotoad:another-branch", ["id": "monotoad:another-branch", "repo": "monotoad", "branch": "another-branch", "keys": ["key"]])
        #expect(!write.settled())
        try ReviewGuideTests().upsert(app, "viewed", ReviewPageTests.branch, ["id": .string(ReviewPageTests.branch), "repo": "loops", "branch": "add-hankles-limited-label", "keys": ["key"]])
        #expect(write.settled())
        write.answered?(true, [:])
        #expect(ReviewMarks.of(app).overrides("loops")["key"] == nil)
    }

    @Test func aHeldFlagFailureDoesNotChangeTheNewRepository() async throws {
        let (app, port) = try await ReviewPageTests().app(protocolClasses: [HeldLookupStub.self, ShipStub.self])
        let pg = ReviewPageState.of(app)
        HeldLookupStub.hold(port, "/loops/viewed")
        app.runner.dispatch("review.flag", via: .key)
        await until("the held flag") { HeldLookupStub.waiting(port, "/loops/viewed") }
        app.router.navigate(.review(repo: "monotoad", branch: "another-branch"))
        pg.sync()
        pg.viewedOverride["another"] = .flagged
        HeldLookupStub.release(port, "/loops/viewed", #"{"ok":false,"err":"flag refused"}"#)
        await until("the flag refusal") { app.runner.runOf("review.flag", ReviewPageTests.branch)?.state == .failed }
        #expect(pg.viewedOverride == ["another": .flagged])
        #expect(ReviewMarks.of(app).overrides("loops").isEmpty)
    }

    @Test func optimisticMarksFollowTheirRepositoryAcrossBranches() async throws {
        let (app, _) = try await ReviewPageTests().app()
        let pg = ReviewPageState.of(app)
        pg.viewedOverride["shared"] = .viewed
        app.router.navigate(.review(repo: "loops", branch: "hankles-next"))
        pg.sync()
        #expect(pg.viewedOverride["shared"] == .viewed)
        app.router.navigate(.review(repo: "monotoad", branch: "another-branch"))
        pg.sync()
        #expect(pg.viewedOverride.isEmpty)
        app.router.navigate(.review(repo: "loops", branch: "add-hankles-limited-label"))
        pg.sync()
        #expect(pg.viewedOverride["shared"] == .viewed)
    }
}
