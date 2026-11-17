import CanopyCore
import Foundation
import Testing
@testable import CanopyUI

@MainActor struct WordsReaderOwnershipTests {
    let id = ShipTests.branch

    func fixture() async throws -> (AppModel, Int) {
        let result = try ShipTests().app()
        let page = ReviewPageState.of(result.0)
        page.sync()
        await until("the initial diff refusal") { page.loadErr != nil }
        return result
    }

    func outline(_ app: AppModel) -> WordsOutline {
        var outline = ShipTests().ownedOutline()
        outline.head = app.store.view(Branch.self, id)?.tip ?? ""
        return outline
    }

    @Test func aCurrentColdActionOpensOnlyAfterValidatedWordsArrive() async throws {
        let (app, _) = try await fixture()
        let words = WordsState.of(app)
        var pending: CheckedContinuation<WordsOutline, Error>?
        words.fetch = { _, _ in try await withCheckedThrowingContinuation { pending = $0 } }
        app.runner.dispatch("title", via: .palette)
        let task = words.load(app, id)
        await until("the owned outline request") { pending != nil }
        #expect(app.insertField == nil)
        pending?.resume(returning: outline(app))
        await task?.value
        #expect(app.insertField == "words.title|\(id)")
    }

    @Test func aNewerImmediateDescSupersedesAColdTitle() async throws {
        let (app, _) = try await fixture()
        let words = WordsState.of(app)
        var pending: CheckedContinuation<WordsOutline, Error>?
        words.fetch = { _, _ in try await withCheckedThrowingContinuation { pending = $0 } }
        app.runner.dispatch("title", via: .palette)
        let task = words.load(app, id)
        await until("the old outline request") { pending != nil }
        app.runner.dispatch("desc", via: .palette)
        let field = app.insertField
        #expect(field == "words.desc|\(id)")
        pending?.resume(returning: outline(app))
        await task?.value
        #expect(app.insertField == field)
        #expect(words.shown[id] != nil)
    }

    @Test func cancellationAndReaderRoundTripsCannotSendDeferredWords() async throws {
        for cancel in ["escape", "visit", "picker"] {
            let (app, port) = try await fixture()
            let words = WordsState.of(app)
            var pending: CheckedContinuation<WordsOutline, Error>?
            words.fetch = { _, _ in try await withCheckedThrowingContinuation { pending = $0 } }
            app.runner.dispatch("title", via: .palette, arg: "new title")
            let task = words.load(app, id)
            await until("the deferred write's outline") { pending != nil }
            switch cancel {
            case "escape":
                _ = app.keys.handle("esc")
                #expect(app.runner.note == "words action cancelled")
            case "visit":
                let route = app.router.route
                app.router.navigate(.machine); app.router.navigate(route)
            default: app.nav.pick("newer choice", [PickItem(label: "kept")]) { _ in }
            }
            app.runner.say("newer feedback")
            pending?.resume(returning: outline(app))
            await task?.value
            #expect(ShipStub.posts(port).isEmpty)
            #expect(words.pending(id) == 0 && app.insertField == nil)
            #expect(app.runner.note == "newer feedback")
        }
    }

    @Test func escapeOnTheBranchLineCancelsTheWordsBeforeItsPickedEndpoint() async throws {
        let (app, port) = try await fixture()
        let page = ReviewPageState.of(app)
        let branch = try #require(page.branch)
        ShipState.of(app).putHistory(branch, [HistoryCommit(sha: "c2", subject: "Second"), HistoryCommit(sha: "c1", subject: "First")])
        app.runner.dispatch("review.line", via: .key)
        app.setCursor("c|c2")
        app.runner.dispatch("line.pick", via: .key)
        let anchor = try #require(page.lineAnchor)
        let words = WordsState.of(app)
        var pending: CheckedContinuation<WordsOutline, Error>?
        words.fetch = { _, _ in try await withCheckedThrowingContinuation { pending = $0 } }
        app.runner.dispatch("title", via: .palette, arg: "must stay unsent")
        let task = words.load(app, id)
        await until("the line reader's outline") { pending != nil }
        _ = app.keys.handle("esc")
        #expect(app.runner.note == "words action cancelled" && page.lineAnchor == anchor)
        pending?.resume(returning: outline(app))
        await task?.value
        #expect(ShipStub.posts(port).isEmpty && words.pending(id) == 0)
        _ = app.keys.handle("esc")
        #expect(page.lineAnchor == nil)
    }

    @Test func staleFailuresAndSupersededReadsCannotConsumeNewerWaiters() async throws {
        let (app, _) = try await fixture()
        let words = WordsState.of(app)
        var pending: [CheckedContinuation<WordsOutline, Error>] = []
        words.fetch = { _, _ in try await withCheckedThrowingContinuation { pending.append($0) } }
        app.runner.dispatch("title", via: .palette)
        let old = words.load(app, id)
        await until("first outline") { pending.count == 1 }
        app.runner.dispatch("why", via: .palette)
        let new = words.load(app, id, force: true)
        await until("second outline") { pending.count == 2 }
        pending[0].resume(throwing: Refusal("obsolete failure"))
        await old?.value
        app.runner.say("newer feedback")
        pending[1].resume(returning: outline(app))
        await new?.value
        #expect(app.insertField == "words.body|\(id)")
        #expect(app.runner.note == "newer feedback")
    }

    @Test func subjectAndSourceMismatchesCannotWakeADeferredAction() async throws {
        for change in ["branch", "head", "source"] {
            let (app, port) = try await fixture()
            let words = WordsState.of(app)
            var pending: CheckedContinuation<WordsOutline, Error>?
            words.fetch = { _, _ in try await withCheckedThrowingContinuation { pending = $0 } }
            app.runner.dispatch("title", via: .palette, arg: "must stay unsent")
            let task = words.load(app, id)
            await until("the qualified outline") { pending != nil }
            var response = outline(app)
            if change == "branch" { response.branch = "other" }
            if change == "head" { response.head = "fffffff" }
            if change == "source" {
                #expect(app.store.applyPatch(try Patch.make(domain: Domain.remote, version: (app.store.versions[Domain.remote] ?? 0) + 1)) == .ok)
                app.runner.say("newer feedback")
            }
            pending?.resume(returning: response)
            await task?.value
            #expect(ShipStub.posts(port).isEmpty && words.shown[id] == nil)
            #expect(app.insertField == nil && words.pending(id) == 0)
            if change == "source" { #expect(app.runner.note == "newer feedback") }
        }
    }

    @Test func replayedOrReplacedPickerDataCannotOpenOrWrite() async throws {
        for command in ["reword", "fold"] {
            for change in ["replay", "outline", "source"] {
                let (app, port) = try await fixture()
                let words = WordsState.of(app)
                words.setShown(id, outline(app))
                app.runner.dispatch(command, via: .palette)
                #expect(app.nav.picker != nil)
                switch change {
                case "replay": app.nav.close(); #expect(app.nav.reopen())
                case "outline":
                    var replacement = outline(app); replacement.commits[1].subject = "replaced"
                    words.setShown(id, replacement)
                default:
                    #expect(app.store.applyPatch(try Patch.make(domain: Domain.remote, version: (app.store.versions[Domain.remote] ?? 0) + 1)) == .ok)
                }
                app.runner.say("newer feedback")
                #expect(app.nav.choose(0))
                #expect(app.insertField == nil && ShipStub.posts(port).isEmpty)
                #expect(app.runner.note == "newer feedback")
            }
        }
    }

    @Test func aFreshPickerKeepsItsExactCommitAndAmbiguousPrefixesRefuse() async throws {
        let (app, port) = try await fixture()
        let words = WordsState.of(app)
        var response = outline(app)
        response.commits = [OutlineCommit(sha: "aa111111", subject: "First"), OutlineCommit(sha: "aa222222", subject: "Second")]
        words.setShown(id, response)
        for command in ["reword", "fold"] {
            app.runner.dispatch(command, via: .palette, arg: "aa changed")
            #expect(app.runner.note?.contains("more than one commit") == true)
            #expect(app.insertField == nil && ShipStub.posts(port).isEmpty)
        }
        app.runner.dispatch("reword", via: .palette)
        #expect(app.nav.choose(0))
        #expect(app.insertField == "words.s|\(id)|aa222222")
    }
}
