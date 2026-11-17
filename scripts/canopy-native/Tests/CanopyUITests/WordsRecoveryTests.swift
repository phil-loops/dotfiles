import CanopyCore
import Foundation
import Testing
@testable import CanopyUI

@MainActor struct WordsRecoveryTests {
    let id = ShipTests.branch

    func fixture() throws -> (AppModel, WordsState, WordsOutline, Int) {
        let (app, port) = try ShipTests().app()
        let words = WordsState.of(app)
        var outline = ShipTests().outline()
        outline.head = app.store.view(Branch.self, id)?.tip ?? ""
        words.setShown(id, outline)
        words.fetch = { _, _ in throw Refusal("refresh unavailable in this case") }
        return (app, words, outline, port)
    }

    func save(_ app: AppModel) throws -> Write {
        let make = try #require(app.registry.command("words.save")?.write)
        return try #require(try make(id, nil))
    }

    func undo(_ app: AppModel, _ inverse: Inverse) throws -> Write {
        let make = try #require(app.registry.command("words.undo")?.write)
        return try #require(try make(id, inverse.arg))
    }

    @Test func aDelayedRunnerRefusalKeepsNewerWordsOnBothBranches() async throws {
        let (app, words, outline, port) = try fixture()
        ShipStub.answer(port, "POST", "/loops/outline", #"{"ok":false,"err":"not saved"}"#)
        let commit = outline.commits[1]
        words.editTo(id, commit, MessageWords(subject: "older edit", body: ""))
        app.runner.dispatch("words.save", via: .key, target: id)
        words.editTo(id, commit, MessageWords(subject: "newer edit", body: "new body"))
        words.setDraft("loops:other", "other-sha", MessageWords(subject: "other branch", body: ""))
        await until("the delayed words refusal") { app.runner.runs["words.save|\(id)"]?.state == .failed }
        #expect(words.valueOf(id, commit) == MessageWords(subject: "newer edit", body: "new body"))
        #expect(words.drafts["loops:other"]?["other-sha"]?.subject == "other branch")
    }

    @Test func aFailedBodyAndAcceptedTitlePreserveTheUnsentBodyDraft() throws {
        let (app, words, outline, _) = try fixture()
        let baseline = words.prOnFile(id)
        words.editPr(id, MessageWords(subject: baseline.subject, body: "B1"))
        let body = try save(app)
        words.editPr(id, MessageWords(subject: "S1", body: words.prValue(id).body))
        let title = try save(app)
        #expect(title.body["prTitle"] == "S1" && title.body["prBody"] == nil)
        body.rollback?()
        title.answered?(true, ["changed": 0, "fields": ["prTitle"]])
        #expect(words.prOnFile(id) == MessageWords(subject: "S1", body: baseline.body))
        #expect(words.prValue(id) == MessageWords(subject: "S1", body: "B1"))
        #expect(words.pending(id) == 1 && words.changed(id).isEmpty)
        #expect(words.valueOf(id, outline.commits[1]).subject == outline.commits[1].subject)
    }

    @Test func independentPRPartsRecoverInEitherFailureOrder() throws {
        for order in [[0, 1], [1, 0]] {
            let (app, words, _, _) = try fixture()
            let baseline = words.prOnFile(id)
            words.editPr(id, MessageWords(subject: baseline.subject, body: "B1"))
            let first = try save(app)
            words.editPr(id, MessageWords(subject: "S1", body: words.prValue(id).body))
            let second = try save(app)
            let writes = [first, second]
            for index in order { writes[index].rollback?() }
            #expect(words.prOnFile(id) == baseline)
            #expect(words.prValue(id) == MessageWords(subject: "S1", body: "B1"))
        }
    }

    @Test func revertingAnInheritedPendingPartDoesNotResurrectTheOlderDraft() throws {
        let (app, words, _, _) = try fixture()
        let baseline = words.prOnFile(id)
        words.editPr(id, MessageWords(subject: baseline.subject, body: "B1"))
        let write = try save(app)
        words.editPr(id, MessageWords(subject: baseline.subject, body: "B2"))
        words.editPr(id, MessageWords(subject: baseline.subject, body: baseline.body))
        write.rollback?()
        #expect(words.prValue(id) == baseline && words.pending(id) == 0)
    }

    @Test func aSuccessfulNoOpCannotUndoAnOlderJournalEntry() throws {
        let (app, words, _, _) = try fixture()
        words.editPr(id, MessageWords(subject: "S1", body: words.prValue(id).body))
        let write = try save(app)
        #expect(write.inverse?(["changed": 0, "fields": []]) == nil)
        write.answered?(true, ["changed": 0, "fields": []])
        #expect(app.runner.note == "words already on file")
        let inverse = try #require(write.inverse?(["changed": 0, "fields": ["prTitle"]]))
        let target = try #require(inverse.arg as? WordsUndo)
        #expect(!target.moves && target.fields == [.title])
    }

    @Test func anAcceptedUndoDoesNotReappearAfterANewerSaveFails() throws {
        let (app, words, _, _) = try fixture()
        words.editPr(id, MessageWords(subject: "S1", body: "B1"))
        let original = try save(app)
        let answer: JSONObject = ["changed": 0, "fields": ["prTitle", "prBody"]]
        original.answered?(true, answer)
        let inverse = try #require(original.inverse?(answer))
        let restoring = try undo(app, inverse)
        words.editPr(id, MessageWords(subject: "S1", body: "B2"))
        let newer = try save(app)
        restoring.answered?(true, ["restored": ["prTitle"], "commits": 0])
        newer.rollback?()
        #expect(words.savedPr[id] == nil)
        #expect(words.prValue(id).body == "B2")
        #expect(words.prOnFile(id).subject != "S1")
    }

    @Test func anUndoRefusalCannotEraseANewerSavedFieldOrDraft() throws {
        let (app, words, _, _) = try fixture()
        words.editPr(id, MessageWords(subject: "S1", body: "B1"))
        let original = try save(app)
        let answer: JSONObject = ["changed": 0, "fields": ["prTitle", "prBody"]]
        original.answered?(true, answer)
        let restoring = try undo(app, try #require(original.inverse?(answer)))
        words.editPr(id, MessageWords(subject: "S2", body: "B1"))
        let newer = try save(app)
        newer.answered?(true, ["changed": 0, "fields": ["prTitle"]])
        words.editPr(id, MessageWords(subject: "S2", body: "new draft"))
        restoring.rollback?()
        #expect(words.prOnFile(id) == MessageWords(subject: "S2", body: "B1"))
        #expect(words.prValue(id) == MessageWords(subject: "S2", body: "new draft"))
    }

    @Test func aValidatedRefreshRetiresOnlyPreviouslyAcceptedOverrides() async throws {
        let (app, words, outline, _) = try fixture()
        words.editPr(id, MessageWords(subject: "S1", body: "B1"))
        let first = try save(app)
        var pending: CheckedContinuation<WordsOutline, Error>?
        words.fetch = { _, _ in try await withCheckedThrowingContinuation { pending = $0 } }
        first.answered?(true, ["changed": 0, "fields": ["prTitle", "prBody"]])
        let task = words.load(app, id)
        await until("the post-save outline") { pending != nil }
        words.editPr(id, MessageWords(subject: "S2", body: "B1"))
        let newer = try save(app)
        var refreshed = outline
        refreshed.draft?.title = "S1"; refreshed.draft?.body = "B1"
        pending?.resume(returning: refreshed)
        await task?.value
        #expect(words.prOnFile(id) == MessageWords(subject: "S2", body: "B1"))
        newer.rollback?()
        #expect(words.prOnFile(id) == MessageWords(subject: "S1", body: "B1"))
        #expect(words.prValue(id).subject == "S2")
    }

    @Test func anUndoWhichPreservesNewerServerFieldsDoesNotClaimToRestoreThem() throws {
        let (app, words, _, _) = try fixture()
        words.editPr(id, MessageWords(subject: "S1", body: words.prValue(id).body))
        let original = try save(app)
        let answer: JSONObject = ["changed": 0, "fields": ["prTitle"]]
        original.answered?(true, answer)
        let restoring = try undo(app, try #require(original.inverse?(answer)))
        restoring.answered?(true, ["restored": [], "commits": 0])
        #expect(restoring.said == nil)
        #expect(app.runner.note == "undo kept newer words · rereading the branch")
        #expect(words.savedPr[id] == nil)
    }


    @Test func explicitlyReturningToAnUnacceptedValueKeepsThatTextWhenItsSaveFails() throws {
        let (app, words, _, _) = try fixture()
        let title = words.prValue(id).subject
        words.editPr(id, MessageWords(subject: title, body: "B1"))
        let original = try save(app)
        words.editPr(id, MessageWords(subject: title, body: "B2"))
        words.editPr(id, MessageWords(subject: title, body: "B1"))
        #expect(words.pending(id) == 0)
        original.rollback?()
        #expect(words.prValue(id).body == "B1" && words.pending(id) == 1)
    }

    @Test func anObservedCanonicalValueRetiresSatisfiedExplicitParts() async throws {
        let (app, words, outline, _) = try fixture()
        let title = words.prValue(id).subject
        words.editPr(id, MessageWords(subject: title, body: "B1"))
        let original = try save(app)
        words.editPr(id, MessageWords(subject: title, body: "B2"))
        words.editPr(id, MessageWords(subject: title, body: "B1"))
        var pending: CheckedContinuation<WordsOutline, Error>?
        words.fetch = { _, _ in try await withCheckedThrowingContinuation { pending = $0 } }
        original.answered?(true, ["changed": 0, "fields": ["prBody"]])
        let task = words.load(app, id)
        await until("the canonical PR body") { pending != nil }
        var response = outline; response.draft?.body = "B1"
        pending?.resume(returning: response)
        await task?.value
        #expect(words.prValue(id).body == "B1" && words.pending(id) == 0)
        #expect(words.drafts[id]?[WordsState.pr] == nil && words.savedPr[id] == nil)
    }


    @Test func aRefreshCannotRetireExplicitTextAgainstAProtectedPendingBaseline() async throws {
        for explicit in ["B1", "B2"] {
            let (app, words, initial, _) = try fixture()
            var baseline = initial; baseline.draft?.body = "B1"
            words.setShown(id, baseline)
            words.editPr(id, MessageWords(subject: words.prValue(id).subject, body: "B2"))
            let original = try save(app)
            let answer: JSONObject = ["changed": 0, "fields": ["prBody"]]
            original.answered?(true, answer)
            await words.load(app, id)?.value
            words.editPr(id, MessageWords(subject: words.prValue(id).subject, body: "B3"))
            words.editPr(id, MessageWords(subject: words.prValue(id).subject, body: explicit))
            var pending: CheckedContinuation<WordsOutline, Error>?
            words.fetch = { _, _ in try await withCheckedThrowingContinuation { pending = $0 } }
            let task = words.load(app, id, force: true)
            await until("the pre-undo outline") { pending != nil }
            let restoring = try undo(app, try #require(original.inverse?(answer)))
            pending?.resume(returning: baseline)
            await task?.value
            #expect(words.prValue(id).body == explicit && words.prOnFile(id).body == "B2")
            #expect(words.pending(id) == (explicit == "B1" ? 1 : 0))
            words.fetch = { _, _ in throw Refusal("follow-up unavailable") }
            restoring.answered?(true, ["restored": ["prBody"], "commits": 0])
            #expect(words.prValue(id).body == explicit)
        }
    }

}
