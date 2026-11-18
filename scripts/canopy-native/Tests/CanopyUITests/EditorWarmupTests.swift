import CanopyCore
import Foundation
import Testing
@testable import CanopyUI

@MainActor @Suite(.serialized) struct EditorWarmupTests {
    let path = "/loops/edit-warm"

    @Test func preparationRunsOncePerRepositoryEpochWithoutChangingTheReader() async throws {
        let (app, port) = try await ReviewPageTests().app()
        let page = ReviewPageState.of(app)
        page.editorWarmEnabled = true
        ShipStub.answer(port, "POST", path, #"{"ok":true}"#)
        let cursor = app.selected, focus = app.pane?.id
        app.runner.say("keep this feedback")
        page.warmEditor(app)
        page.warmEditor(app)
        await until("the editor warmup") { ShipStub.posts(port).filter { $0.path == path }.count == 1 }
        page.sync()
        try await Task.sleep(nanoseconds: 30_000_000)
        #expect(ShipStub.posts(port).filter { $0.path == path }.count == 1)
        #expect(app.selected == cursor && app.pane?.id == focus)
        #expect([nil, "keep this feedback"].contains(app.runner.note), "the warmup writes no note of its own; ours may have expired under load")
        #expect(page.helix == nil)
    }

    @Test func readOnlySessionsNeverPrepareMachineCheckouts() async throws {
        let (app, port) = try await ReviewPageTests().app()
        let page = ReviewPageState.of(app)
        page.editorWarmEnabled = true
        app.runner.refusal = { command in command.write != nil ? "read only" : nil }
        page.warmEditor(app)
        page.sync()
        try await Task.sleep(nanoseconds: 30_000_000)
        #expect(!ShipStub.posts(port).contains { $0.path == path })
        #expect(page.editorWarmRepos.isEmpty)
    }

    @Test func initialWarmupDoesNotNeedToWaitForTheStateSnapshot() async throws {
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
