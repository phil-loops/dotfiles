import CanopyCore
import Foundation
import Testing
@testable import CanopyUI

@MainActor @Suite(.serialized) struct EditorRecoveryTests {
    let catalogPath = "/loops/edit-workspaces"
    let recoveryPath = "/loops/edit-recover"
    let session = "11111111-2222-3333-4444-555555555555"
    let operation = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    let sha = String(repeating: "4", count: 40)

    func encoded(_ body: JSONObject) throws -> String {
        String(decoding: try JSONEncoder().encode(body), as: UTF8.self)
    }

    func workspace(_ app: AppModel) -> JSONObject {
        let page = ReviewPageState.of(app)
        return ["session": .string(session), "branch": .string(page.target!.name), "expectedTip": .string(page.tip),
                "baseSha": .string(page.baseSha), "operation": .string(operation), "sha": .string(sha),
                "message": "edit a.ts", "retryable": true]
    }

    func catalog(_ app: AppModel, row: JSONObject? = nil) throws -> String {
        try encoded(["ok": true, "epoch": .string(app.store.epoch), "workspaces": [.object(row ?? workspace(app))]])
    }

    func receipt(_ app: AppModel, row: JSONObject? = nil) throws -> String {
        let page = ReviewPageState.of(app), row = row ?? workspace(app)
        let files = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(page.payload!.data.files))
        return try encoded(["ok": true, "epoch": .string(app.store.epoch), "session": row["session"]!, "operation": row["operation"]!,
            "repo": "loops", "branch": row["branch"]!, "expectedTip": row["expectedTip"]!, "baseSha": row["baseSha"]!, "sha": row["sha"]!,
            "tree": .string(String(repeating: "3", count: 40)), "paths": .array(page.payload!.data.files.map { .string($0.path) }),
            "files": files, "history": ["sha": row["sha"]!, "subject": "edit a.ts", "own": true], "wrote": 1])
    }

    func open(_ app: AppModel) async {
        app.runner.dispatch("review.helix.recover", via: .key, target: ReviewPageState.of(app).id)
        await ReviewPageState.of(app).editorRecoveryTask?.value
    }

    @Test func aPickedSaveUsesItsOriginalOperationAndPaintsItsVerifiedReceipt() async throws {
        let (app, port) = try await HelixOwnershipTests().app()
        let page = ReviewPageState.of(app), old = page.tip
        ShipStub.answer(port, "POST", catalogPath, try catalog(app))
        ShipStub.answer(port, "POST", recoveryPath, try receipt(app))
        await open(app)
        #expect(app.nav.picker?.title == "saved Helix edits")
        app.nav.choose(0)
        await until("the recovered commit") { page.tip == sha }
        let post = try #require(ShipStub.posts(port).first { $0.path == recoveryPath })
        #expect(post.body["session"] == .string(session) && post.body["operation"] == .string(operation))
        #expect(post.body["expectedTip"] == .string(old))
        #expect(page.helix == nil && page.diffCurrent)
    }

    @Test func catalogRepliesCannotOpenAPickerAfterNavigationOrServerReplacement() async throws {
        for change in ["navigation", "epoch"] {
            let (app, port) = try await HelixOwnershipTests().app()
            let page = ReviewPageState.of(app), response = try catalog(app)
            HeldLookupStub.hold(port, catalogPath)
            app.runner.dispatch("review.helix.recover", via: .key, target: page.id)
            let task = page.editorRecoveryTask
            await until("the workspace catalog") { HeldLookupStub.waiting(port, catalogPath) }
            if change == "navigation" { app.router.navigate(.machine) }
            else { app.store.hydrate(Snapshot(epoch: "replacement", versions: [:])) }
            app.runner.say("newer feedback")
            HeldLookupStub.release(port, catalogPath, response)
            await task?.value
            #expect(app.nav.picker == nil && app.runner.note == "newer feedback")
            #expect(!ShipStub.posts(port).contains { $0.path == recoveryPath })
        }
    }

    @Test func aPickerCannotCommitAfterItsBranchMoves() async throws {
        let (app, port) = try await HelixOwnershipTests().app()
        let page = ReviewPageState.of(app)
        ShipStub.answer(port, "POST", catalogPath, try catalog(app))
        await open(app)
        var branch = try #require(app.store.rawView("branch", page.id))
        branch["tip"] = .string(String(repeating: "5", count: 40))
        #expect(app.store.applyPatch(try Patch.make(domain: Domain.git, version: (app.store.versions[Domain.git] ?? 0) + 1,
            upserts: ["branch": [page.id: .object(branch)]])) == .ok)
        app.nav.choose(0)
        try await Task.sleep(nanoseconds: 30_000_000)
        #expect(!ShipStub.posts(port).contains { $0.path == recoveryPath })
    }

    @Test func aMismatchedReceiptCannotMoveTheBranch() async throws {
        let (app, port) = try await HelixOwnershipTests().app()
        let page = ReviewPageState.of(app), old = page.tip
        ShipStub.answer(port, "POST", catalogPath, try catalog(app))
        var other = workspace(app)
        other["operation"] = .string(session)
        ShipStub.answer(port, "POST", recoveryPath, try receipt(app, row: other))
        await open(app)
        app.nav.choose(0)
        await until("the refused receipt") { app.runner.note?.contains("couldn't verify") == true }
        #expect(page.tip == old)
    }

    @Test func aSaveWhoseRefAlreadyMovedCanFinishCheckoutRecovery() async throws {
        let (app, port) = try await HelixOwnershipTests().app()
        var row = workspace(app)
        row["expectedTip"] = .string(String(repeating: "9", count: 40))
        row["sha"] = .string(ReviewPageState.of(app).tip)
        ShipStub.answer(port, "POST", catalogPath, try catalog(app, row: row))
        ShipStub.answer(port, "POST", recoveryPath, try receipt(app, row: row))
        await open(app)
        app.nav.choose(0)
        await until("the completed checkout recovery") { app.runner.note == "recovered the saved Helix edit" }
        #expect(ShipStub.posts(port).contains { $0.path == recoveryPath })
    }

    @Test func readOnlySessionsNeverReadOrRecoverMachineWorkspaces() async throws {
        let (app, port) = try await HelixOwnershipTests().app()
        app.runner.refusal = { command in command.write != nil ? "read only" : nil }
        await open(app)
        #expect(!ShipStub.posts(port).contains { [catalogPath, recoveryPath].contains($0.path) })
    }

    @Test(arguments: ["epoch", "tip"]) func queuedRecoveryRechecksItsSourceBeforeSending(_ change: String) async throws {
        let (app, port) = try await HelixOwnershipTests().app()
        let page = ReviewPageState.of(app), id = page.id
        ShipStub.answer(port, "POST", catalogPath, try catalog(app))
        HeldLookupStub.hold(port, "/blocked-recovery")
        app.registry.register(Command(id: "held-recovery-predecessor", title: "Held", scope: .global, write: { _, _ in
            Write(path: "/blocked-recovery", body: [:], settled: { true }, failed: "held", silent: true)
        }))
        app.runner.dispatch("held-recovery-predecessor", via: .key, target: id)
        await until("the held predecessor") { HeldLookupStub.waiting(port, "/blocked-recovery") }
        await open(app)
        app.nav.choose(0)
        if change == "epoch" { app.store.hydrate(Snapshot(epoch: "replacement", versions: [:])) }
        else {
            var branch = try #require(app.store.rawView("branch", id))
            branch["tip"] = .string(String(repeating: "5", count: 40))
            #expect(app.store.applyPatch(try Patch.make(domain: Domain.git, version: (app.store.versions[Domain.git] ?? 0) + 1,
                upserts: ["branch": [id: .object(branch)]])) == .ok)
        }
        app.runner.say("newer feedback")
        HeldLookupStub.release(port, "/blocked-recovery", #"{"ok":true}"#)
        await until("the queued recovery refusal") { app.runner.runOf("review.helix.recover.commit", id)?.state == .failed }
        #expect(!ShipStub.posts(port).contains { $0.path == recoveryPath })
        #expect(app.runner.note == "newer feedback")
    }
}
