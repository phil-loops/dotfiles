import CanopyTestSupport
import CanopyCore
import Foundation
import Testing
@testable import CanopyUI

@MainActor @Suite(.serialized) struct ReviewGuideTests {
    let base = ReviewPageTests()
    let probe = ReviewProbeTests()

    func upsert(_ app: AppModel, _ kind: String, _ id: String, _ value: JSONValue) throws {
        let patch: JSONValue = ["domain": "review", "version": .number(Double((app.store.versions["review"] ?? 0) + 1)),
                                "upserts": .object([kind: .object([id: value])])]
        app.store.applyPatch(try Patch.decode(JSONEncoder().encode(patch)))
    }

    func keys(_ app: AppModel, _ names: String...) { for name in names { app.keys.handle(name) } }

    @Test func aSingleFileIsPickableThroughEveryFileKey() async throws {
        let (app, _) = try await base.app(probe.payload([("models/message.ts", "@@ -1,1 +1,1 @@\n-old\n+new")]))
        let pg = ReviewPageState.of(app)
        for key in ["g", "b", "f"] {
            keys(app, "space", key)
            #expect(app.nav.picker?.items.map(\.label) == ["models/message.ts"])
            #expect(app.keys.layer == .picker)
            keys(app, "ret")
            #expect(app.pane?.id == reviewDiffPane && pg.here?.path == "models/message.ts")
        }
    }

    @Test func matchingBasenamesKeepTheirFullPathsInThePicker() async throws {
        let (app, _) = try await base.app(probe.payload([("queries/message.ts", "@@ -1,1 +1,1 @@\n-a\n+A"), ("models/message.ts", "@@ -1,1 +1,1 @@\n-b\n+B")]))
        keys(app, "space", "g")
        #expect(app.nav.picker?.items.map(\.label) == ["queries/message.ts", "models/message.ts"])
        app.nav.typed("models/message")
        #expect(app.nav.shown.map(\.label) == ["models/message.ts"])
        keys(app, "ret")
        #expect(ReviewPageState.of(app).here?.path == "models/message.ts")
    }

    @Test func flagsOpenTheirExactBlockAndSelectionDoesNotMoveCode() async throws {
        let (app, _) = try await base.app()
        let pg = ReviewPageState.of(app)
        let view = try #require(pg.views.last)
        let block = try #require(view.blocks.last)
        pg.viewedOverride[block.key] = .flagged
        let source = pg.here?.key
        app.runner.dispatch("review.guide", via: .key)
        let entry = try #require(ReviewGuide.entries(app).first { $0.kind == .flag(block.key) })
        app.setCursor(entry.key)
        #expect(pg.here?.key == source && app.pane?.id == reviewGuidePane)
        keys(app, "ret")
        #expect(!pg.guideOpen && pg.here?.key == pg.stopOf(block: block.key, in: view.file.path))
        #expect(app.pane?.id == reviewDiffPane)
    }

    @Test func aThreadOnReadCodeOpensWithoutErasingReadMarks() async throws {
        let (app, _) = try await base.app()
        let pg = ReviewPageState.of(app)
        let id = ReviewPageTests.branch + "#T1"
        for view in pg.views { for block in view.blocks { pg.viewedOverride[block.key] = .viewed } }
        let marks = pg.viewedOverride
        #expect(!pg.stopKeys.contains("t|\(id)"))
        app.runner.dispatch("review.guide", via: .key)
        let thread = try #require(ReviewGuide.entries(app).first { $0.kind == .thread(id) })
        app.setCursor(thread.key)
        keys(app, "ret")
        #expect(pg.tab == "conversation" && app.pane?.id == ShipSeam.conversationPane && app.selected == "t|\(id)")
        #expect(ShipState.of(app).unfold[id] == true && pg.viewedOverride == marks)
    }

    @Test func aResolvedOrOutdatedThreadIsNotReturnWork() async throws {
        let (app, _) = try await base.app()
        let id = ReviewPageTests.branch + "#T1"
        var thread = try #require(app.store.rawView("thread", id))
        thread["resolved"] = true
        try upsert(app, "thread", id, .object(thread))
        #expect(!ReviewGuide.entries(app).contains { $0.kind == .thread(id) })
        thread["resolved"] = false
        thread["outdated"] = true
        try upsert(app, "thread", id, .object(thread))
        #expect(!ReviewGuide.entries(app).contains { $0.kind == .thread(id) })
    }

    @Test func aFlagRemovedBeforeActivationCannotNavigate() async throws {
        let (app, _) = try await base.app()
        let pg = ReviewPageState.of(app)
        let block = try #require(pg.views.last?.blocks.first)
        pg.viewedOverride[block.key] = .flagged
        app.runner.dispatch("review.guide", via: .key)
        let entry = try #require(ReviewGuide.entries(app).first { $0.kind == .flag(block.key) })
        let source = pg.here?.key
        pg.viewedOverride[block.key] = .unread
        app.runner.dispatch("review.guide.go", via: .key, arg: entry.key)
        #expect(pg.here?.key == source && pg.guideOpen)
        #expect(app.runner.note == "that item changed · reopen Return to")
    }

    @Test func anOldFlagStaysVisibleButNeverUsesANearbyLine() async throws {
        let (app, _) = try await base.app()
        let pg = ReviewPageState.of(app)
        let id = ReviewPageTests.branch
        try upsert(app, "viewed", id, ["id": .string(id), "repo": "loops", "branch": "add-hankles-limited-label", "keys": [],
                                      "flagged": ["missing-block"], "flags": [["key": "missing-block", "at": 1, "path": "a.ts", "line": 2, "text": "the old issue"]]])
        app.runner.dispatch("review.guide", via: .key)
        let flag = try #require(ReviewGuide.entries(app).first { $0.kind == .flag("missing-block") })
        #expect(flag.stop == nil && flag.title == "a.ts:2")
        let source = pg.here?.key
        app.setCursor(flag.key)
        keys(app, "ret")
        #expect(pg.here?.key == source && pg.guideOpen)
        #expect(app.runner.note?.contains("not in this diff") == true)
    }

    @Test func aScopeChangeInvalidatesGuideEntriesAndOldFilePickers() async throws {
        let (app, port) = try await base.app(protocolClasses: [HeldLookupStub.self, ShipStub.self])
        let pg = ReviewPageState.of(app)
        app.runner.dispatch("review.guide", via: .key)
        let oldEntry = try #require(ReviewGuide.entries(app).first)
        keys(app, "space", "g", "esc")
        HeldLookupStub.hold(port, "/loops/commit-diff")
        pg.setStretch("c2")
        await until("the held scope") { HeldLookupStub.waiting(port, "/loops/commit-diff") }
        app.runner.dispatch("review.files", via: .key)
        #expect(app.nav.picker == nil && app.runner.note == "reading the current diff")
        HeldLookupStub.release(port, "/loops/commit-diff", #"{"sha":"c2","files":[{"path":"a.ts","add":1,"del":1,"patch":"@@ -1,1 +1,1 @@\n-old\n+new"}]}"#)
        await until("the scoped diff") { pg.commitFiles?.sha == "c2" }
        #expect(!pg.guideOpen)
        let source = pg.here?.key
        app.nav.reopen()
        keys(app, "ret")
        #expect(pg.here?.key == source && app.runner.note == "the diff changed · open the file picker again")
        app.runner.dispatch("review.guide", via: .key)
        app.runner.dispatch("review.guide.go", via: .key, arg: oldEntry.key)
        #expect(pg.here?.key == source && pg.guideOpen && app.runner.note == "that item changed · reopen Return to")
    }

    @Test(arguments: ["tip", "base"]) func retainedCodeCannotSupplyNewDiffDestinations(_ change: String) async throws {
        let (app, port) = try await base.app(protocolClasses: [HeldLookupStub.self, ShipStub.self])
        let pg = ReviewPageState.of(app)
        let id = ReviewPageTests.branch
        let view = try #require(pg.views.last)
        let block = try #require(view.blocks.first)
        try upsert(app, "viewed", id, ["id": .string(id), "repo": "loops", "branch": "add-hankles-limited-label", "keys": [],
                                      "flagged": [.string(block.key)], "flags": [["key": .string(block.key), "at": 1, "path": .string(view.file.path), "line": 6, "text": "flagged code"]]])
        HeldLookupStub.hold(port, "/loops/node")
        if change == "tip" {
            var branch = try #require(app.store.rawView("branch", id))
            branch["tip"] = "changed-tip"
            try upsert(app, "branch", id, .object(branch))
            pg.sync()
        } else {
            pg.setBase(.main)
        }
        let query = "branch=add-hankles-limited-label"
        await until("the held new diff") { HeldLookupStub.waiting(port, "/loops/node", query: query) }
        #expect(pg.payload != nil && pg.payload?.key != pg.keyOf && !pg.views.isEmpty)
        app.runner.dispatch("review.guide", via: .key)
        let entry = try #require(ReviewGuide.entries(app).first { $0.kind == .flag(block.key) })
        #expect(entry.stop == nil && ReviewGuide.progress(app) == "reading the current diff…")
        let source = pg.here?.key
        app.runner.dispatch("review.guide.go", via: .key, arg: entry.key)
        #expect(pg.here?.key == source && app.runner.note == "reading the current diff · try again when it lands")
        app.runner.dispatch("review.files", via: .key)
        #expect(app.nav.picker == nil && app.runner.note == "reading the current diff")
        HeldLookupStub.release(port, "/loops/node", probe.payload([]), query: query)
        await until("the new empty diff") { pg.payload?.key == pg.keyOf }
        app.runner.dispatch("review.files", via: .key)
        #expect(app.runner.note == "no changed files in this diff")
    }

    @Test func anEmptyQueueOffersReadingWithoutClaimingCompletion() async throws {
        let (app, _) = try await base.app()
        let pg = ReviewPageState.of(app)
        for thread in pg.threads {
            var value = try #require(app.store.rawView("thread", thread.id))
            value["resolved"] = true
            try upsert(app, "thread", thread.id, .object(value))
        }
        #expect(ReviewGuide.entries(app).isEmpty)
        #expect(ReviewGuide.progress(app).hasPrefix("0 of "))
        app.runner.dispatch("review.guide", via: .key)
        #expect(app.selected == ReviewGuide.emptyKey(app))
        keys(app, "ret")
        #expect(!pg.guideOpen && app.pane?.id == reviewDiffPane)
    }
}
