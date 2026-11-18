import CanopyCore
import Foundation
import Testing
@testable import CanopyUI

@MainActor @Suite(.serialized) struct RenameOwnershipTests {
    let id = ShipTests.branch
    let branch = "add-hankles-limited-label"
    let position = CodeLookup.Position(path: "a.ts", line: 2, character: 0)

    func preview(_ app: AppModel, sha: String? = nil) throws -> String {
        let body: JSONObject = ["ok": true, "sha": .string(sha ?? app.store.view(Branch.self, id)!.tip),
                                "old": "before", "files": [["path": "a.ts", "edits": 2]], "diff": "-before\n+renamed"]
        return String(decoding: try JSONEncoder().encode(body), as: UTF8.self)
    }

    func begin(_ app: AppModel) {
        CodeLookup.of(app).rename(position, branch: branch, repo: "loops")
        app.nav.typed("renamed")
    }

    @Test func theInitialNamePickerCannotBeReplayedOrRetargeted() async throws {
        for change in ["replay", "visit", "source"] {
            let (app, port) = try await LookupTests().app()
            ShipStub.answer(port, "POST", "/loops/lsp/rename", try preview(app))
            begin(app)
            switch change {
            case "replay": app.nav.close(); #expect(app.nav.reopen())
            case "visit":
                app.nav.close()
                app.router.navigate(.machine)
                app.router.navigate(.review(repo: "loops", branch: branch))
                #expect(app.nav.reopen())
            default:
                #expect(app.store.applyPatch(try Patch.make(domain: Domain.remote, version: (app.store.versions[Domain.remote] ?? 0) + 1)) == .ok)
            }
            #expect(app.nav.choose())
            await CodeLookup.of(app).renameTask?.value
            #expect(!ShipStub.posts(port).contains { $0.path == "/loops/lsp/rename" })
            #expect(CodeLookup.of(app).renameTask == nil)
        }
    }

    @Test func aPreviewMustNameTheExactFullTipThatWasShown() async throws {
        for sha in ["", "e1b98e2a", String(repeating: "f", count: 40)] {
            let (app, port) = try await LookupTests().app()
            ShipStub.answer(port, "POST", "/loops/lsp/rename", try preview(app, sha: sha))
            begin(app); #expect(app.nav.choose())
            await CodeLookup.of(app).renameTask?.value
            #expect(app.nav.picker == nil)
            #expect(CodeLookup.of(app).pop?.text.contains("couldn't validate") == true)
            #expect(!ShipStub.posts(port).contains { $0.body["apply"] == true })
        }
    }

    @Test func aNewObservedSourceCannotPublishAnOldPreview() async throws {
        let (app, port) = try await LookupTests().app()
        HeldLookupStub.hold(port, "/loops/lsp/rename")
        begin(app); #expect(app.nav.choose())
        let task = CodeLookup.of(app).renameTask
        await until("the source-owned rename preview") { HeldLookupStub.waiting(port, "/loops/lsp/rename") }
        #expect(app.store.applyPatch(try Patch.make(domain: Domain.remote, version: (app.store.versions[Domain.remote] ?? 0) + 1)) == .ok)
        app.runner.say("newer feedback")
        HeldLookupStub.release(port, "/loops/lsp/rename", try preview(app))
        await task?.value
        #expect(app.nav.picker == nil && CodeLookup.of(app).pop == nil)
        #expect(app.runner.note == "newer feedback")
    }

    @Test func enterOnlyOpensAPreviewAndCannotCommitIt() async throws {
        let (app, port) = try await LookupTests().app()
        ShipStub.answer(port, "POST", "/loops/lsp/rename", try preview(app))
        let page = ReviewPageState.of(app)
        app.focus(pane: reviewDiffPane)
        page.goTo(file: "a.ts")
        app.keys.handle("space"); app.keys.handle("r")
        #expect(app.nav.picker?.title == "rename to…")
        app.nav.typed("renamed")
        app.keys.handle("ret")
        await CodeLookup.of(app).renameTask?.value
        let requests = ShipStub.posts(port).filter { $0.path == "/loops/lsp/rename" }
        #expect(requests.count == 1)
        #expect(requests.first?.body["apply"] == false)
        #expect(requests.first?.body["sha"] == .string(app.store.view(Branch.self, id)!.tip))
        #expect(app.nav.picker == nil && app.runner.armed == nil)
        let text = CodeLookup.of(app).pop?.text ?? ""
        #expect(text.contains("Rename preview · loops/\(branch) @"))
        #expect(text.contains("2 edits in 1 file · preview only · edit in Helix"))
        #expect(text.contains("```diff\n-before\n+renamed\n```"))
        app.keys.handle("ret")
        #expect(app.runner.armed == nil)
        #expect(app.nav.reopen())
        app.keys.handle("ret")
        await CodeLookup.of(app).renameTask?.value
        #expect(ShipStub.posts(port).filter { $0.path == "/loops/lsp/rename" }.count == 1)
        #expect(!ShipStub.posts(port).contains { $0.body["apply"] == true })
    }

    @Test func malformedPreviewFilesCannotBecomeAPreview() async throws {
        let cases: [[JSONValue]] = [[], [["path": "../outside.ts", "edits": 1]], [["path": "/outside.ts", "edits": 1]],
            [["path": "a.ts", "edits": 0]], [["path": "a.ts", "edits": 1], ["path": "a.ts", "edits": 1]],
            [["path": "a.ts", "edits": .number(9_000_000_000_000_000_000)], ["path": "b.ts", "edits": .number(9_000_000_000_000_000_000)]]]
        for files in cases {
            let (app, port) = try await LookupTests().app()
            var body = try JSONDecoder().decode(JSONValue.self, from: Data(preview(app).utf8)).object!
            body["files"] = .array(files)
            ShipStub.answer(port, "POST", "/loops/lsp/rename", String(decoding: try JSONEncoder().encode(body), as: UTF8.self))
            begin(app); #expect(app.nav.choose())
            await CodeLookup.of(app).renameTask?.value
            #expect(app.nav.picker == nil)
            #expect(CodeLookup.of(app).pop?.text.contains("couldn't validate") == true)
            #expect(!ShipStub.posts(port).contains { $0.body["apply"] == true })
        }
    }

}
