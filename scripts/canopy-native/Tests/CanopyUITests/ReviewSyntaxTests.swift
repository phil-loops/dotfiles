import CanopyTestSupport
import CanopyCore
import Foundation
import Testing
@testable import CanopyUI

@MainActor @Suite(.serialized) struct ReviewSyntaxTests {
    let source = SyntaxSourceTests()
    let path = "/loops/syntax/units"
    var reply: String {
        #"{"ok":true,"sha":"\#(source.tip)","units":[],"functions":[{"line":1,"endLine":2,"name":"first"},{"line":3,"endLine":4,"name":"second"},{"line":20,"endLine":23,"name":"third"}],"classes":[{"line":21,"endLine":23,"name":"class Third"}]}"#
    }
    var hiddenReply: String {
        #"{"ok":true,"sha":"\#(source.tip)","units":[],"functions":[{"line":10,"endLine":23,"name":"hidden function"}],"classes":[]}"#
    }
    var file: String { (1...30).map { "line \($0)" }.joined(separator: "\n") }

    func app() async throws -> (AppModel, Int) { try await source.app() }
    func run(_ app: AppModel, _ command: String = "review.function.next") throws -> Task<Void, Never> {
        app.runner.dispatch(command, via: .key)
        return try #require(ReviewSyntax.of(app).task)
    }

    func upsertBranch(_ app: AppModel, _ branch: JSONObject) throws {
        let patch: JSONValue = ["domain": "git", "version": .number(Double((app.store.versions["git"] ?? 0) + 1)),
                                "upserts": ["branch": .object([ReviewPageTests.branch: .object(branch)])]]
        app.store.applyPatch(try Patch.decode(JSONEncoder().encode(patch)))
    }

    func fileQuery(_ port: Int) -> String? {
        HeldLookupStub.lock.withLock { HeldLookupStub.pending[HeldLookupStub.key(port, "/loops/file")]?.first?.request.url?.query }
    }

    @Test func keysWalkQualifiedFunctionsAndTypesWithoutChangingTheirMeanings() async throws {
        let (app, port) = try await app(), page = ReviewPageState.of(app)
        ShipStub.answer(port, "POST", path, reply)
        app.keys.handle("]"); app.keys.handle("f")
        await ReviewSyntax.of(app).task?.value
        #expect(page.here?.key == "l|a.ts|R:3" && app.runner.note == "second")
        app.keys.handle("["); app.keys.handle("f")
        await ReviewSyntax.of(app).task?.value
        #expect(page.here?.key == "l|a.ts|R:1" && app.runner.note == "first")
        app.keys.handle("]"); app.keys.handle("t")
        await ReviewSyntax.of(app).task?.value
        #expect(page.here?.key == "l|a.ts|R:21" && app.runner.note == "class Third")
        #expect(CodeLookup.of(app).pop == nil)
    }

    @Test(arguments: [false, true]) func eofRemovalKeepsPreviousAndNextFunctionsInTheirSourceDirection(_ zeroContext: Bool) async throws {
        let tail = zeroContext ? "@@ -11,1 +10,0 @@\n-deleted" : "@@ -9,3 +9,2 @@\n tail\n last\n-deleted"
        let patch = "@@ -1,3 +1,3 @@\n function first() {\n-old\n+new\n }\n" + tail
        let payload = ReviewProbeTests().payload([("a.ts", patch)])
        let (app, port) = try await ReviewPageTests().app(payload, protocolClasses: [HeldLookupStub.self, ShipStub.self])
        let page = ReviewPageState.of(app)
        ShipStub.answer(port, "POST", path, source.answer(source.tip, name: "first"))
        let removal = try #require(page.stops.last { $0.row?.left?.kind == .del && $0.row?.right == nil })
        page.setCursor(removal.key)
        await (try run(app)).value
        #expect(page.here?.key == removal.key && app.runner.note?.contains("last function") == true)
        await (try run(app, "review.function.prev")).value
        #expect(page.here?.key == "l|a.ts|R:1" && app.runner.note == "first")
        let lastAnchor = try #require(page.fileOf("a.ts")).file
        #expect(lineAnchors(lastAnchor).last?.at == 11)
    }

    @Test(arguments: [false, true]) func aBoundaryAfterAOneLineFunctionCanStillMoveBackToIt(_ gap: Bool) async throws {
        let patch = "@@ -8,3 +8,1 @@\n-const dead = 1;\n export function f() {}\n-console.log(\"trace\");"
        let (app, port) = try await ReviewPageTests().app(ReviewProbeTests().payload([("a.ts", patch)]))
        let page = ReviewPageState.of(app)
        ShipStub.answer(port, "POST", path, #"{"ok":true,"sha":"\#(source.tip)","units":[],"functions":[{"line":8,"endLine":8,"name":"f"}],"classes":[]}"#)
        let origin = try #require(page.stops.last { gap ? $0.kind == .gap : $0.row?.left?.old == 10 })
        page.setCursor(origin.key)
        await (try run(app)).value
        #expect(page.here?.key == origin.key)
        await (try run(app, "review.function.prev")).value
        #expect(page.here?.key == "l|a.ts|R:8" && app.runner.note == "f")
        await (try run(app, "review.function.prev")).value
        #expect(page.here?.key == "l|a.ts|R:8" && app.runner.note?.contains("first function") == true)
    }

    @Test func leavingBeforeTheTaskStartsSendsNoSyntaxRequest() async throws {
        let (app, port) = try await app()
        let task = try run(app)
        app.router.navigate(.machine)
        await task.value
        #expect(!ShipStub.posts(port).contains { $0.path == path })
        #expect(CodeLookup.of(app).pop == nil)
    }

    @Test(arguments: ["cursor", "focus", "mode", "page", "scope", "source"]) func aReaderRoundTripCannotReviveThePendingMotion(_ change: String) async throws {
        let (app, port) = try await app(), page = ReviewPageState.of(app)
        HeldLookupStub.hold(port, path)
        let task = try run(app)
        await until("held syntax motion") { HeldLookupStub.waiting(port, path) }
        let cursor = page.here?.key
        switch change {
        case "cursor":
            app.keys.handle("j"); app.keys.handle("k")
        case "focus":
            app.focus(pane: ShipSeam.wordsPane); app.focus(pane: reviewDiffPane)
        case "mode":
            app.keys.setMode(.select); app.keys.setMode(.normal)
        case "page":
            app.router.navigate(.machine)
            app.router.navigate(.review(repo: "loops", branch: "add-hankles-limited-label"))
        case "scope":
            ShipStub.answer(port, "GET", "/loops/commit-diff", ReviewPageTests.payload)
            page.setStretch(source.older)
            await until("older scope") { page.commitFiles?.sha == source.older }
            page.setStretch("")
            page.setCursor(cursor)
        case "source":
            var branch = try #require(app.store.rawView("branch", ReviewPageTests.branch))
            branch["tip"] = .string(source.older)
            try upsertBranch(app, branch)
            branch["tip"] = .string(source.tip)
            try upsertBranch(app, branch)
        default: break
        }
        HeldLookupStub.release(port, path, reply)
        await task.value
        #expect(page.here?.key == cursor && CodeLookup.of(app).pop == nil)
        #expect(app.runner.note != "second")
    }

    @Test func escapeCancelsPendingSyntaxAndAStaleErrorCannotReplaceFeedback() async throws {
        let (app, port) = try await app(), page = ReviewPageState.of(app)
        HeldLookupStub.hold(port, path)
        let task = try run(app)
        await until("pending syntax") { HeldLookupStub.waiting(port, path) }
        let cursor = page.here?.key
        app.keys.handle("esc")
        app.runner.say("newer feedback")
        HeldLookupStub.release(port, path, #"{"ok":false,"message":"old grammar failure"}"#)
        await task.value
        #expect(page.here?.key == cursor && app.runner.note == "newer feedback" && CodeLookup.of(app).pop == nil)
    }

    @Test func aNewerLookupKeepsItsPopoverAndDefeatsTheOlderSyntaxMotion() async throws {
        let (app, port) = try await app(), page = ReviewPageState.of(app)
        HeldLookupStub.hold(port, path)
        let task = try run(app)
        await until("pending syntax") { HeldLookupStub.waiting(port, path) }
        ShipStub.answer(port, "POST", "/loops/lsp/hover", #"{"ok":true,"contents":"newer type"}"#)
        let hover = try #require(CodeLookup.of(app).hover(CodeLookup.Position(path: "a.ts", line: 2, character: 0), .commit(repo: "loops", sha: source.tip)))
        await hover.value
        HeldLookupStub.release(port, path, reply)
        await task.value
        #expect(CodeLookup.of(app).pop?.text == "newer type" && page.here?.key == "l|a.ts|R:2")
    }

    @Test func cancellationDuringContextReadCannotUnfoldOrMoveTheReader() async throws {
        let (app, port) = try await app(), page = ReviewPageState.of(app)
        ShipStub.answer(port, "POST", path, hiddenReply)
        HeldLookupStub.hold(port, "/loops/file")
        let before = page.contextGen, cursor = page.here?.key
        let task = try run(app)
        await until("pending source context") { HeldLookupStub.waiting(port, "/loops/file") }
        #expect(page.contextGen == before && page.contextOf("a.ts") == nil)
        app.keys.handle("esc")
        HeldLookupStub.release(port, "/loops/file", file)
        await task.value
        #expect(page.contextGen == before && page.contextOf("a.ts") == nil && page.here?.key == cursor)
    }

    @Test func aValidContextReadUnfoldsAtomicallyAndLandsEvenFromTheGapItReplaces() async throws {
        let (app, port) = try await app(), page = ReviewPageState.of(app)
        ShipStub.answer(port, "POST", path, hiddenReply)
        HeldLookupStub.hold(port, "/loops/file")
        let gap = try #require(page.stops.first { $0.path == "a.ts" && $0.kind == .gap && $0.at == 1 })
        page.setCursor(gap.key)
        let task = try run(app)
        await until("gap context") { HeldLookupStub.waiting(port, "/loops/file") }
        #expect(fileQuery(port)?.contains(source.tip) == true)
        HeldLookupStub.release(port, "/loops/file", file)
        await task.value
        #expect(page.here?.key == "l|a.ts|R:10" && app.runner.note == "hidden function")
    }

    @Test func unavailableSyntaxCannotClaimThatThereAreNoFunctions() async throws {
        for message in ["grammar process failed", "no grammar for this file"] {
            let (app, port) = try await app()
            ShipStub.answer(port, "POST", path, #"{"ok":true,"units":null,"functions":null,"classes":null,"message":"\#(message)"}"#)
            await (try run(app)).value
            #expect(app.runner.note == message && CodeLookup.of(app).pop == nil)
        }
    }

    @Test func preparedContextCannotApplyToAnotherScopeAndRangeReadsUseTheEndObject() async throws {
        let (app, port) = try await app(), page = ReviewPageState.of(app)
        HeldLookupStub.hold(port, "/loops/file")
        let read = Task { await page.prepareContext("a.ts") }
        await until("prepared context") { HeldLookupStub.waiting(port, "/loops/file") }
        HeldLookupStub.release(port, "/loops/file", file)
        let prepared = try #require(await read.value)
        ShipStub.answer(port, "GET", "/loops/commit-diff", ReviewPageTests.payload)
        let range = "\(source.older)..\(source.tip)"
        page.setStretch(range)
        await until("range context") { page.commitFiles?.sha == range }
        #expect(!page.reveal(prepared, at: 1, n: 10))
        let reveal = Task { await page.reveal("a.ts", at: 1, n: 10) }
        await until("range source context") { HeldLookupStub.waiting(port, "/loops/file") }
        #expect(fileQuery(port)?.contains(source.tip) == true && fileQuery(port)?.contains("..") == false)
        HeldLookupStub.release(port, "/loops/file", file)
        await reveal.value
    }
}
