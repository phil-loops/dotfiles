import CanopyCore
import Foundation
import Testing
@testable import CanopyUI

@MainActor @Suite(.serialized) struct HelixOwnershipTests {
    let branch = "add-hankles-limited-label"
    let id = ReviewPageTests.branch
    let path = "/loops/review-helix"

    func app() async throws -> (AppModel, Int) {
        let (app, port) = try await LookupTests().app()
        app.focus(pane: reviewDiffPane)
        ReviewPageState.of(app).setCursor("l|a.ts|R:2")
        return (app, port)
    }

    func answer(_ page: ReviewPageState, sha: String? = nil, dir: String = "/tmp/owned.diffbase") throws -> String {
        let body: JSONObject = ["ok": true, "sha": .string(sha ?? page.tip), "dir": .string(dir)]
        return String(decoding: try JSONEncoder().encode(body), as: UTF8.self)
    }

    func requestBody(_ request: URLRequest) throws -> JSONValue {
        if let data = request.httpBody { return try JSONDecoder().decode(JSONValue.self, from: data) }
        let stream = try #require(request.httpBodyStream)
        stream.open()
        defer { stream.close() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    func ready(_ app: AppModel, _ port: Int) async throws -> HelixOpen {
        let page = ReviewPageState.of(app)
        ShipStub.answer(port, "POST", path, try answer(page))
        app.keys.handle("i")
        await page.helixTask?.value
        let open = try #require(page.helix)
        #expect(open.dir == "/tmp/owned.diffbase")
        return open
    }

    @Test func preparationNeverStartsAfterTheReaderLeaves() async throws {
        let (app, port) = try await app(), page = ReviewPageState.of(app)
        app.keys.handle("i")
        let task = page.helixTask
        app.router.navigate(.machine)
        await task?.value
        #expect(page.helix == nil)
        #expect(!ShipStub.posts(port).contains { $0.path == path })
    }

    @Test func heldPreparationCannotSpeakOrInstallAfterReaderOrSourceMovement() async throws {
        for change in ["cursor", "focus", "mode", "source"] {
            let (app, port) = try await app(), page = ReviewPageState.of(app)
            HeldLookupStub.hold(port, path)
            app.keys.handle("i")
            let task = page.helixTask
            await until("the editor preparation") { HeldLookupStub.waiting(port, path) }
            switch change {
            case "cursor": page.setCursor("l|a.ts|R:3"); page.setCursor("l|a.ts|R:2")
            case "focus": app.focus(pane: ShipSeam.wordsPane); app.focus(pane: reviewDiffPane)
            case "mode": app.keys.setMode(.select); app.keys.setMode(.normal)
            default:
                var moved = try #require(app.store.rawView("branch", id))
                moved["tip"] = "0123456789abcdef0123456789abcdef01234567"
                #expect(app.store.applyPatch(try Patch.make(domain: Domain.git, version: (app.store.versions[Domain.git] ?? 0) + 1,
                    upserts: ["branch": [id: .object(moved)]])) == .ok)
            }
            app.runner.say("newer feedback")
            HeldLookupStub.release(port, path, try answer(page))
            await task?.value
            #expect(page.helix == nil && app.runner.note == "newer feedback")
        }
    }

    @Test func anotherBranchsCommitOrAFetchMidPreparationStillOpensHelix() async throws {
        // the repo-wide git/remote versions move on every other branch's commit and every fetch;
        // keyed on them, `o` was dropped mid-request and sat at "checking … out for Helix…" (2026-11-17)
        let (app, port) = try await app(), page = ReviewPageState.of(app)
        HeldLookupStub.hold(port, path)
        app.keys.handle("i")
        let task = page.helixTask
        await until("the editor preparation") { HeldLookupStub.waiting(port, path) }
        #expect(app.store.applyPatch(try Patch.make(domain: Domain.remote, version: (app.store.versions[Domain.remote] ?? 0) + 1)) == .ok)
        #expect(app.store.applyPatch(try Patch.make(domain: Domain.git, version: (app.store.versions[Domain.git] ?? 0) + 1)) == .ok)
        HeldLookupStub.release(port, path, try answer(page))
        await task?.value
        #expect(page.helix?.dir == "/tmp/owned.diffbase")
    }

    @Test func aDroppedPreparationNeverLeavesCheckingStanding() async throws {
        let (app, port) = try await app(), page = ReviewPageState.of(app)
        HeldLookupStub.hold(port, path)
        app.keys.handle("i")
        let task = page.helixTask
        await until("the editor preparation") { HeldLookupStub.waiting(port, path) }
        #expect(app.runner.note?.hasPrefix("checking ") == true)
        app.keys.setMode(.select); app.keys.setMode(.normal)
        HeldLookupStub.release(port, path, try answer(page))
        await task?.value
        #expect(page.helix == nil)
        #expect(app.runner.note?.hasPrefix("Helix didn't open") == true, "the opening that ended says so")
    }

    @Test func escapeAndOldSamePathRepliesCannotReplaceANewerSession() async throws {
        for reply in ["success", "failure"] {
            let (app, port) = try await app(), page = ReviewPageState.of(app)
            HeldLookupStub.hold(port, path)
            app.keys.handle("i")
            let oldTask = page.helixTask, old = try #require(page.helix)
            await until("the first preparation") { HeldLookupStub.waiting(port, path) }
            app.keys.handle("esc")
            #expect(page.helix == nil && app.runner.note == "Helix opening cancelled")
            app.keys.handle("i")
            let newTask = page.helixTask, new = try #require(page.helix)
            #expect(old.session != new.session)
            HeldLookupStub.release(port, path, reply == "success" ? try answer(page, dir: "/tmp/old") : #"{"ok":false,"err":"old failure"}"#)
            await oldTask?.value
            #expect(page.helix?.session == new.session && page.helix?.dir == nil)
            await until("the replacement preparation") { HeldLookupStub.waiting(port, path) }
            HeldLookupStub.release(port, path, try answer(page, dir: "/tmp/new"))
            await newTask?.value
            #expect(page.helix?.session == new.session && page.helix?.dir == "/tmp/new")
        }
    }

    @Test func preparationRequiresItsExactFullHeadAndAbsoluteCheckout() async throws {
        for response in [#"{"ok":true,"dir":"/tmp/x"}"#, #"{"ok":true,"dir":"/tmp/x","sha":"short"}"#,
                         #"{"ok":true,"dir":"/tmp/x","sha":"ffffffffffffffffffffffffffffffffffffffff"}"#,
                         #"{"ok":true,"dir":"relative","sha":"e1b98e2a133f5c4e82b6c74fb31efca5b5c3b233"}"#] {
            let (app, port) = try await app(), page = ReviewPageState.of(app)
            ShipStub.answer(port, "POST", path, response)
            app.keys.handle("i")
            await page.helixTask?.value
            #expect(page.helix == nil)
            #expect(app.runner.note?.contains("couldn't prepare Helix") == true)
        }
    }

    @Test func quitKeepsItsOriginalBranchAndRepositoryAndUsesRunnerWriteOnce() async throws {
        let (app, port) = try await app(), page = ReviewPageState.of(app)
        let open = try await ready(app, port)
        var repo = try #require(app.store.rawView("repo", "loops"))
        repo["id"] = "other"; repo["name"] = "other"
        var branch = try #require(app.store.rawView("branch", id))
        branch["id"] = .string("other:\(self.branch)"); branch["repo"] = "other"
        #expect(app.store.applyPatch(try Patch.make(domain: Domain.git, version: (app.store.versions[Domain.git] ?? 0) + 1,
            upserts: ["repo": ["other": .object(repo)], "branch": ["other:\(self.branch)": .object(branch)]])) == .ok)
        ShipStub.answer(port, "GET", "/other/node", ReviewPageTests.payload)
        app.router.navigate(.review(repo: "other", branch: self.branch))
        await until("the other repository at the same head") { page.id == "other:\(self.branch)" && page.diffCurrent }
        let cursor = app.selected, focus = app.pane?.id
        HeldLookupStub.hold(port, path)
        page.landHelix(app, session: open.session)
        page.landHelix(app, session: open.session)
        let replay = HelixLanding(open: open, dir: open.dir!, reader: nil)
        app.runner.dispatch("review.helix.land", via: .palette, target: id, arg: replay)
        await until("the owned editor write") { HeldLookupStub.waiting(port, path) }
        let request = try #require(HeldLookupStub.lock.withLock { HeldLookupStub.pending[HeldLookupStub.key(port, path)]?.first?.request })
        let body = try requestBody(request)
        #expect(body["branch"] == .string(self.branch) && body["sha"] == .string(open.source.tip) && body["dir"] == .string(open.dir!))
        #expect(request.value(forHTTPHeaderField: "X-Stack-Write") == "1")
        #expect(request.value(forHTTPHeaderField: "X-Stack-Via") == "key")
        #expect(HeldLookupStub.lock.withLock { HeldLookupStub.pending[HeldLookupStub.key(port, path)]?.count } == 1)
        #expect(app.selected == cursor && app.pane?.id == focus && page.pendingHelixReturn == nil)
        ShipStub.answer(port, "POST", "/other/review-helix", try answer(page, dir: "/tmp/other.diffbase"))
        app.keys.handle("i")
        await page.helixTask?.value
        let newer = try #require(page.helix)
        #expect(newer.source.repo == "other" && newer.dir == "/tmp/other.diffbase")
        HeldLookupStub.hold(port, "/other/review-helix")
        page.landHelix(app, session: newer.session)
        #expect(page.pendingHelixReturn?.source.id == "other:\(self.branch)" && page.pendingHelixReturn?.session == newer.session)
        app.runner.say("newer feedback")
        HeldLookupStub.release(port, path, #"{"ok":false,"err":"held refusal"}"#)
        await until("the refused original editor write") { app.runner.runOf("review.helix.land", id)?.state == .failed }
        #expect(app.runner.note == "newer feedback" && app.selected == cursor && page.helix == nil)
        #expect(page.pendingHelixReturn?.source.id == "other:\(self.branch)" && page.pendingHelixReturn?.session == newer.session)
        await until("the queued other-repo landing") { HeldLookupStub.waiting(port, "/other/review-helix") }
        HeldLookupStub.release(port, "/other/review-helix", #"{"ok":true,"nothing":true}"#)
        await until("the newer editor landing") { app.runner.runOf("review.helix.land", "other:\(self.branch)")?.state == .done }
    }

    @Test func oldTerminalCallbacksCannotMoveOrQuitANewerSession() async throws {
        let (app, port) = try await app(), page = ReviewPageState.of(app)
        let old = try await ready(app, port)
        ShipStub.answer(port, "POST", path, #"{"ok":true,"nothing":true}"#)
        page.landHelix(app, session: old.session)
        await until("the first landing") { app.runner.runOf("review.helix.land", id)?.state == .done }
        let new = try await ready(app, port)
        page.moveHelix(session: new.session, path: "a.ts", line: 3)
        page.moveHelix(session: old.session, path: "wrong.ts", line: 80)
        page.finishHelix(app, session: old.session, exitCode: 0)
        #expect(page.helix?.session == new.session && page.helixAt?.path == "a.ts" && page.helixAt?.line == 3)
        #expect(ShipStub.posts(port).filter { $0.body["op"] == "land" }.count == 1)
    }

    @Test func aNonzeroExitKeepsEditsAndNeverCommits() async throws {
        let (app, port) = try await app(), page = ReviewPageState.of(app)
        let open = try await ready(app, port)
        page.finishHelix(app, session: open.session, exitCode: 1)
        #expect(page.helix == nil && app.runner.note?.contains("edits are saved in") == true)
        #expect(!ShipStub.posts(port).contains { $0.body["op"] == "land" })
    }

    @Test func anUnreadyDiffCannotPrepareAnEditor() async throws {
        let (app, port) = try await app(), page = ReviewPageState.of(app)
        HeldLookupStub.hold(port, "/loops/node")
        page.forgetDiffs()
        await until("the unready diff") { !page.diffCurrent && HeldLookupStub.waiting(port, "/loops/node") }
        #expect(!page.beginEdit(app) && !page.openHelixWhole(app))
        #expect(page.helix == nil && !ShipStub.posts(port).contains { $0.path == path })
        HeldLookupStub.release(port, "/loops/node", ReviewPageTests.payload)
    }

    @Test func aReturnAnchorCannotReviveAfterReaderMovementOrAWordRoundTrip() async throws {
        for outcome in ["failed", "nothing", "committed"] {
            for movement in ["cursor", "word"] {
                let (app, port) = try await app(), page = ReviewPageState.of(app)
                let open = try await ready(app, port)
                HeldLookupStub.hold(port, path)
                page.landHelix(app, session: open.session)
                await until("the held editor landing") { HeldLookupStub.waiting(port, path) }
                if movement == "cursor" {
                    page.setCursor("l|a.ts|R:3"); page.setCursor("l|a.ts|R:2"); page.setCursor("l|a.ts|R:3")
                } else {
                    let original = page.word
                    page.word = ("l|a.ts|R:2", .right, 1..<2)
                    page.word = original
                }
                let cursor = app.selected
                app.runner.say("newer feedback")
                let response = outcome == "failed" ? #"{"ok":false,"err":"refused"}"# : outcome == "nothing"
                    ? #"{"ok":true,"nothing":true}"# : #"{"ok":true,"sha":"2222222222222222222222222222222222222222"}"#
                HeldLookupStub.release(port, path, response)
                await until("the editor answer") { [.done, .failed].contains(app.runner.runOf("review.helix.land", id)?.state) }
                #expect(page.pendingHelixReturn == nil && app.runner.note == "newer feedback")
                let payload = try #require(page.payload)
                page.land(payload.key, payload.data)
                #expect(app.selected == cursor)
            }
        }
    }

    @Test(arguments: ["empty", "partial", "no-op-without-ok", "sha-without-ok", "old", "short", "invalid", "failed"])
    func aLandingNeedsAnExplicitVerifiedOutcome(_ outcome: String) async throws {
        let (app, port) = try await app(), page = ReviewPageState.of(app)
        let open = try await ready(app, port)
        let response: String
        switch outcome {
        case "empty": response = "{}"
        case "partial": response = #"{"ok":true}"#
        case "no-op-without-ok": response = #"{"nothing":true}"#
        case "sha-without-ok": response = #"{"sha":"2222222222222222222222222222222222222222"}"#
        case "old": response = #"{"ok":true,"sha":"\#(page.tip)"}"#
        case "short": response = #"{"ok":true,"sha":"2222222"}"#
        case "invalid": response = #"{"ok":true,"sha":"zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz"}"#
        default: response = #"{"ok":false,"nothing":true,"err":"refused"}"#
        }
        ShipStub.answer(port, "POST", path, response)
        page.landHelix(app, session: open.session)
        await until("the unverified landing") { [.done, .failed].contains(app.runner.runOf("review.helix.land", id)?.state) }
        #expect(page.pendingHelixReturn == nil)
        #expect(app.runner.note?.contains("saved in /tmp/owned.diffbase") == true)
        #expect(app.runner.note?.contains("committed") != true && app.runner.note != "nothing changed")
        #expect(ShipStub.posts(port).filter { $0.body["op"] == "land" }.count == 1)
    }

    @Test func aCurrentReturnFollowsOnlyTheAcknowledgedCommit() async throws {
        let (app, port) = try await app(), page = ReviewPageState.of(app)
        let open = try await ready(app, port)
        page.moveHelix(session: open.session, path: "a.ts", line: 20)
        HeldLookupStub.hold(port, path)
        page.landHelix(app, session: open.session)
        await until("the held editor landing") { HeldLookupStub.waiting(port, path) }
        let sha = String(repeating: "2", count: 40)
        HeldLookupStub.release(port, path, #"{"ok":true,"sha":"\#(sha)","message":"edit a.ts"}"#)
        await until("the acknowledged editor commit") { app.runner.runOf("review.helix.land", id)?.state == .done }
        #expect(page.pendingHelixReturn?.commit == sha)
        let patch = "@@ -1,3 +1,30 @@\n-one\n-two\n-three\n" + (1...30).map { "+line \($0)" }.joined(separator: "\n")
        ShipStub.answer(port, "GET", "/loops/node", ReviewProbeTests().payload([("a.ts", patch)]))
        var branch = try #require(app.store.rawView("branch", id))
        branch["tip"] = .string(sha)
        #expect(app.store.applyPatch(try Patch.make(domain: Domain.git, version: (app.store.versions[Domain.git] ?? 0) + 1,
            upserts: ["branch": [id: .object(branch)]])) == .ok)
        await until("the acknowledged diff return") { page.diffCurrent && app.selected == "l|a.ts|R:20" }
        #expect(page.pendingHelixReturn == nil)
    }

    @Test(arguments: [false, true]) func aFileOutsideTheDiffUpdatesOnlyItsStillOwnedWindow(_ move: Bool) async throws {
        let (app, port) = try await app(), page = ReviewPageState.of(app)
        let tip = page.tip, sha = String(repeating: "2", count: 40)
        ShipStub.answer(port, "GET", "/loops/lsp/src", #"{"path":"lib/z.ts","sha":"\#(tip)","text":"one\ntwo\nold three\nfour"}"#)
        page.show(Loc(repo: "loops", sha: tip, path: "lib/z.ts", line: 2))
        await until("the original file") { page.sideText != nil }
        let window = try #require(page.code)
        ShipStub.answer(port, "POST", path, try answer(page))
        app.keys.handle("o")
        await page.helixTask?.value
        let open = try #require(page.helix)
        page.moveHelix(session: open.session, path: "lib/z.ts", line: 3)
        HeldLookupStub.hold(port, path)
        page.landHelix(app, session: open.session)
        await until("the file edit landing") { HeldLookupStub.waiting(port, path) }
        if move { app.keys.handle("j") }
        ShipStub.answer(port, "GET", "/loops/lsp/src", #"{"path":"lib/z.ts","sha":"\#(sha)","text":"one\ntwo\nnew three\nfour"}"#)
        HeldLookupStub.release(port, path, #"{"ok":true,"sha":"\#(sha)","message":"edit z.ts"}"#)
        await until("the file edit answer") { app.runner.runOf("review.helix.land", id)?.state == .done }
        if move {
            #expect(window.doc?.sha == tip && app.selected == "s:4")
        } else {
            await until("the committed file") { window.text?.contains("new three") == true }
            #expect(page.code === window && window.doc?.sha == sha && app.selected == "s:3")
        }
        #expect(page.pendingHelixReturn == nil)
    }

    @Test func switchingFilesInHelixDefersTheWindowUntilItsAcknowledgedObject() async throws {
        let (app, port) = try await app(), page = ReviewPageState.of(app)
        let tip = page.tip, sha = String(repeating: "2", count: 40)
        ShipStub.answer(port, "GET", "/loops/lsp/src", #"{"path":"lib/original.ts","sha":"\#(tip)","text":"one\ntwo"}"#)
        page.show(Loc(repo: "loops", sha: tip, path: "lib/original.ts", line: 2))
        await until("the original file") { page.sideText != nil }
        let window = try #require(page.code)
        ShipStub.answer(port, "POST", path, try answer(page))
        app.keys.handle("o")
        await page.helixTask?.value
        let open = try #require(page.helix)
        page.moveHelix(session: open.session, path: "lib/other.ts", line: 20)
        HeldLookupStub.hold(port, path)
        HeldLookupStub.hold(port, "/loops/lsp/src")
        page.landHelix(app, session: open.session)
        await until("the switched-file landing") { HeldLookupStub.waiting(port, path) }
        #expect(window.doc?.path == "lib/original.ts" && !HeldLookupStub.waiting(port, "/loops/lsp/src"))
        HeldLookupStub.release(port, path, #"{"ok":true,"sha":"\#(sha)","message":"edit other.ts"}"#)
        await until("the acknowledged switched file") { HeldLookupStub.waiting(port, "/loops/lsp/src") }
        let text = (1...25).map { "line \($0)" }.joined(separator: "\n")
        let response: JSONObject = ["path": "lib/other.ts", "sha": .string(sha), "text": .string(text)]
        HeldLookupStub.release(port, "/loops/lsp/src", String(decoding: try JSONEncoder().encode(response), as: UTF8.self))
        await until("the new file bytes") { window.text == text }
        #expect(page.code === window && window.doc?.sha == sha && window.doc?.path == "lib/other.ts" && app.selected == "s:20")
        #expect(page.pendingHelixReturn == nil)
    }

    @Test(arguments: ["epoch", "tip"]) func aQueuedEditorWriteRevalidatesAfterItsPredecessor(_ change: String) async throws {
        let (app, port) = try await app(), page = ReviewPageState.of(app)
        let open = try await ready(app, port)
        HeldLookupStub.hold(port, "/blocked-write")
        app.registry.register(Command(id: "held-editor-predecessor", title: "Held", scope: .global, write: { _, _ in
            Write(path: "/blocked-write", body: [:], settled: { true }, failed: "held", silent: true)
        }))
        app.runner.dispatch("held-editor-predecessor", via: .key, target: id)
        await until("the held predecessor") { HeldLookupStub.waiting(port, "/blocked-write") }
        HeldLookupStub.hold(port, path)
        page.landHelix(app, session: open.session)
        if change == "epoch" {
            let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../CanopyCoreTests/Fixtures/state.json")
            var state = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: fixture)).object!
            state["epoch"] = "new-server"
            app.store.hydrate(try Snapshot.decode(JSONEncoder().encode(state)))
        } else {
            var branch = try #require(app.store.rawView("branch", id))
            branch["tip"] = .string(String(repeating: "2", count: 40))
            #expect(app.store.applyPatch(try Patch.make(domain: Domain.git, version: (app.store.versions[Domain.git] ?? 0) + 1,
                upserts: ["branch": [id: .object(branch)]])) == .ok)
        }
        app.runner.say("newer feedback")
        HeldLookupStub.release(port, "/blocked-write", #"{"ok":true}"#)
        await until("the local editor refusal") { app.runner.runOf("review.helix.land", id)?.state == .failed }
        #expect(!HeldLookupStub.waiting(port, path) && page.pendingHelixReturn == nil)
        #expect(app.runner.note == "newer feedback")
        #expect(ShipStub.posts(port).filter { $0.body["op"] == "land" }.isEmpty)
    }

    @Test func historicalCoordinatesCannotOpenTheCurrentCheckout() async throws {
        let (app, port) = try await app(), page = ReviewPageState.of(app)
        let historical = String(repeating: "1", count: 40)
        ShipStub.answer(port, "GET", "/loops/commit-diff", ReviewPageTests.payload)
        page.commitScopeChanged(historical)
        await until("the historical diff") { page.commitFiles?.sha == historical }
        #expect(!page.beginEdit(app) && !page.openHelixWhole(app))
        #expect(page.helix == nil && !ShipStub.posts(port).contains { $0.path == path })
        page.commitScopeChanged(nil)
        ShipStub.answer(port, "GET", "/loops/lsp/src", #"{"path":"lib/old.ts","sha":"x","text":"one\ntwo"}"#)
        page.show(Loc(repo: "loops", sha: historical, path: "lib/old.ts", line: 1))
        await until("the historical file") { page.sideText != nil }
        #expect(!page.openHelixWhole(app) && page.helix == nil)
    }
}
