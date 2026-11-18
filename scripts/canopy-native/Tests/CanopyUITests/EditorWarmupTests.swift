import CanopyCore
import Foundation
import Testing
@testable import CanopyUI

@MainActor @Suite(.serialized) struct EditorWarmupTests {
    let path = "/loops/edit-session"
    let releasePath = "/loops/edit-release"

    func answer(_ preparation: EditorPreparation, owner: String? = nil) throws -> String {
        let body: JSONObject = ["ok": true, "sha": .string(preparation.source.tip), "baseSha": .string(preparation.base),
            "epoch": .string(preparation.source.epoch), "session": .string(preparation.session), "viewOwner": .string(owner ?? preparation.owner),
            "dir": "/tmp/review-workspace", "attachment": ["script": "/tmp/canopy-editor",
                "record": .string("/tmp/canopy-edits/\(preparation.session)/session.json"), "token": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"]]
        return String(decoding: try JSONEncoder().encode(body), as: UTF8.self)
    }

    func prepare(_ app: AppModel, _ port: Int, held: Bool = false) async throws -> EditorPreparation {
        let page = ReviewPageState.of(app)
        page.editorWarmEnabled = true
        ShipStub.answer(port, "POST", releasePath, #"{"ok":true,"released":true}"#)
        if held { HeldLookupStub.hold(port, path) }
        page.warmEditor(app)
        let preparation = try #require(page.editorPreparation)
        if held {
            await until("the held review preparation") { HeldLookupStub.waiting(port, path) }
        } else {
            ShipStub.answer(port, "POST", path, try answer(preparation))
            _ = await preparation.task.value
        }
        return preparation
    }

    @Test func preparationRunsOncePerSourceWithoutChangingTheReader() async throws {
        let (app, port) = try await ReviewPageTests().app()
        let page = ReviewPageState.of(app)
        let cursor = app.selected, focus = app.pane?.id
        app.runner.say("keep this feedback")
        let preparation = try await prepare(app, port)
        page.warmEditor(app)
        await until("the editor warmup") { ShipStub.posts(port).filter { $0.path == path }.count == 1 }
        page.sync()
        try await Task.sleep(nanoseconds: 30_000_000)
        #expect(ShipStub.posts(port).filter { $0.path == path }.count == 1)
        #expect(app.selected == cursor && app.pane?.id == focus)
        #expect([nil, "keep this feedback"].contains(app.runner.note), "the warmup writes no note of its own; ours may have expired under load")
        #expect(page.helix == nil)
        #expect(page.editorPreparation === preparation)
        let body = try #require(ShipStub.posts(port).first { $0.path == path }?.body)
        #expect(body["session"]?.string == preparation.session && body["viewOwner"]?.string == preparation.owner)
        #expect(body["expectedTip"]?.string == page.tip && body["baseSha"]?.string == page.baseSha)
    }

    @Test func openingHandsOffTheReadyAttachmentWithoutAnotherPreparationRequest() async throws {
        let (app, port) = try await HelixOwnershipTests().app(), page = ReviewPageState.of(app)
        let preparation = try await prepare(app, port)
        page.setCursor("l|a.ts|R:3")
        app.keys.handle("o")
        await page.helixTask?.value
        let open = try #require(page.helix)
        #expect(open.lease == preparation.session && open.dir == "/tmp/review-workspace")
        #expect(open.path == "a.ts" && open.line == 3)
        #expect(open.editBase == preparation.base && open.source.sameBranch(as: preparation.source))
        #expect(ShipStub.posts(port).filter { $0.path == path }.count == 1)
        #expect(!ShipStub.posts(port).contains { $0.path == releasePath })
        #expect(page.editorPreparation == nil && page.helixPreparation == nil)
    }

    @Test func openingJoinsTheExistingPreparationWhileItIsStillRunning() async throws {
        let (app, port) = try await HelixOwnershipTests().app(), page = ReviewPageState.of(app)
        let preparation = try await prepare(app, port, held: true)
        app.keys.handle("o")
        await Task.yield()
        #expect(HeldLookupStub.lock.withLock { HeldLookupStub.pending[HeldLookupStub.key(port, path)]?.count } == 1)
        HeldLookupStub.release(port, path, try answer(preparation))
        await page.helixTask?.value
        #expect(page.helix?.lease == preparation.session)
        #expect(!ShipStub.posts(port).contains { $0.path == path || $0.path == releasePath })
    }

    @Test func cancellingAJoinedPreparationReleasesItBeforeTheResponseArrives() async throws {
        let (app, port) = try await HelixOwnershipTests().app(), page = ReviewPageState.of(app)
        let preparation = try await prepare(app, port, held: true)
        app.keys.handle("o")
        let task = page.helixTask
        #expect(page.cancelHelixPreparation())
        await until("the explicit release") { ShipStub.posts(port).contains { $0.path == releasePath } }
        let body = try #require(ShipStub.posts(port).first { $0.path == releasePath }?.body)
        #expect(body["session"]?.string == preparation.session && body["viewOwner"]?.string == preparation.owner)
        HeldLookupStub.release(port, path, try answer(preparation))
        await task?.value
        #expect(page.helix == nil)
    }

    @Test(arguments: ["navigation", "base", "epoch", "hydration", "readOnly"])
    func aPreparedWorkspaceIsReleasedWhenItsOwnerChanges(_ change: String) async throws {
        let (app, port) = try await HelixOwnershipTests().app(), page = ReviewPageState.of(app)
        let preparation = try await prepare(app, port)
        switch change {
        case "navigation": app.router.navigate(.machine)
        case "base":
            var payload = try #require(page.payload?.data)
            payload.baseSha = String(repeating: "2", count: 40)
            page.land(page.keyOf, payload)
        case "readOnly": app.runner.refusal = { command in command.write != nil ? "read only" : nil }
        default:
            let raw: JSONValue = ["epoch": .string(change == "epoch" ? "new-epoch" : app.store.epoch),
                "versions": ["git": 1], "entities": .object(app.store.raw.mapValues { .object($0) })]
            app.store.hydrate(try Snapshot.decode(JSONEncoder().encode(raw)))
        }
        page.warmEditor(app)
        await until("the stale workspace release") { ShipStub.posts(port).contains { $0.path == releasePath } }
        let body = try #require(ShipStub.posts(port).first { $0.path == releasePath }?.body)
        #expect(body["session"]?.string == preparation.session && body["viewOwner"]?.string == preparation.owner)
        #expect(page.editorPreparation !== preparation && page.helix == nil)
        page.releaseEditorPreparation(app)
        await page.editorReleaseTask?.value
    }

    @Test func anAnswerWithAnotherOwnerCannotBecomeTheActiveEditor() async throws {
        let (app, port) = try await HelixOwnershipTests().app(), page = ReviewPageState.of(app)
        let preparation = try await prepare(app, port, held: true)
        app.keys.handle("o")
        HeldLookupStub.release(port, path, try answer(preparation, owner: UUID().uuidString.lowercased()))
        await page.helixTask?.value
        #expect(page.helix == nil)
        await until("the rejected workspace release") { ShipStub.posts(port).contains { $0.path == releasePath } }
    }

    @Test func aReadyAttachmentCannotBypassANewReadOnlyRestriction() async throws {
        let (app, port) = try await HelixOwnershipTests().app(), page = ReviewPageState.of(app)
        _ = try await prepare(app, port)
        app.runner.refusal = { command in command.write != nil ? "read only" : nil }
        app.keys.handle("o")
        await page.helixTask?.value
        await page.editorReleaseTask?.value
        #expect(page.helix == nil && page.editorPreparation == nil)
        #expect(ShipStub.posts(port).contains { $0.path == releasePath })
    }

    @Test func movingTheBaseCancelsAJoinedPreparationBeforeItsAnswer() async throws {
        let (app, port) = try await HelixOwnershipTests().app(), page = ReviewPageState.of(app)
        let preparation = try await prepare(app, port, held: true)
        app.keys.handle("o")
        let task = page.helixTask
        var payload = try #require(page.payload?.data)
        payload.baseSha = String(repeating: "2", count: 40)
        page.land(page.keyOf, payload)
        #expect(page.helix == nil)
        await until("the changed base's cancellation") { ShipStub.posts(port).contains { $0.path == releasePath } }
        HeldLookupStub.release(port, path, try answer(preparation))
        await task?.value
        #expect(page.helix == nil)
        page.releaseEditorPreparation(app)
        await page.editorReleaseTask?.value
    }

    @Test func aQueuedSaveDoesNotPrepareAnotherWorkspaceAtItsOldTip() async throws {
        let (app, port) = try await HelixOwnershipTests().app(), page = ReviewPageState.of(app)
        _ = try await prepare(app, port)
        app.keys.handle("o")
        await page.helixTask?.value
        let open = try #require(page.helix)
        let commitPath = "/loops/edit-commit"
        HeldLookupStub.hold(port, commitPath)
        page.landHelix(app)
        await until("the queued editor save") { HeldLookupStub.waiting(port, commitPath) }
        page.sync()
        page.warmEditor(app)
        #expect(page.editorPreparation == nil)
        #expect(ShipStub.posts(port).filter { $0.path == path }.count == 1)
        HeldLookupStub.release(port, commitPath, try HelixOwnershipTests().nothing(open))
        await until("the next preparation after the save") { page.editorPreparation != nil }
        #expect(app.runner.runOf("review.helix.land", page.id)?.state == .done)
        page.releaseEditorPreparation(app)
        await page.editorReleaseTask?.value
    }

    @Test func readOnlySessionsNeverPrepareMachineCheckouts() async throws {
        let (app, port) = try await ReviewPageTests().app()
        let page = ReviewPageState.of(app)
        page.editorWarmEnabled = true
        app.runner.refusal = { command in command.write != nil ? "read only" : nil }
        page.warmEditor(app)
        page.sync()
        try await Task.sleep(nanoseconds: 30_000_000)
        #expect(!ShipStub.posts(port).contains { $0.path == path || $0.path == "/loops/edit-warm" })
        #expect(page.editorWarmRepos.isEmpty)
        #expect(page.editorPreparation == nil)
    }

    @Test func initialWarmupDoesNotNeedToWaitForTheStateSnapshot() async throws {
        let path = "/loops/edit-warm"
        let (app, port) = try await ReviewPageTests().app()
        let page = ReviewPageState.of(app)
        page.editorWarmEnabled = true
        var snapshot = Snapshot(epoch: "", versions: [:])
        app.store.hydrate(snapshot)
        ShipStub.answer(port, "POST", path, #"{"ok":true}"#)
        page.warmEditor(app)
        await until("the initial warmup") { ShipStub.posts(port).contains { $0.path == path } }
        let request = try #require(ShipStub.posts(port).last { $0.path == path })
        #expect(request.body["branch"] == "add-hankles-limited-label")
        #expect(request.body["epoch"] == nil && request.body["expectedTip"] == nil)
        snapshot.epoch = "new-epoch"
        app.store.hydrate(snapshot)
        page.warmEditor(app)
        try await Task.sleep(nanoseconds: 30_000_000)
        #expect(ShipStub.posts(port).filter { $0.path == path }.count == 1)
    }
}
