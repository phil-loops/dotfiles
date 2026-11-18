import AppKit
import CanopyCore
import Foundation
import SwiftTerm
import SwiftUI
import Testing
@testable import CanopyUI

@MainActor @Suite(.serialized) struct HelixOwnershipTests {
    let branch = "add-hankles-limited-label"
    let id = ReviewPageTests.branch
    let path = "/loops/edit-session"
    let commitPath = "/loops/edit-commit"

    func app() async throws -> (AppModel, Int) {
        let (app, port) = try await LookupTests().app()
        app.focus(pane: reviewDiffPane)
        ReviewPageState.of(app).setCursor("l|a.ts|R:2")
        return (app, port)
    }

    func answer(_ page: ReviewPageState, sha: String? = nil, dir: String = "/tmp/owned.diffbase") throws -> String {
        let body: JSONObject = ["ok": true, "sha": .string(sha ?? page.tip), "dir": .string(dir),
                                "session": "11111111-2222-3333-4444-555555555555", "baseSha": .string(page.baseSha), "epoch": .string(page.app!.store.epoch),
                                "attachment": ["script": "/tmp/canopy-editor", "record": "/tmp/canopy-edits/11111111-2222-3333-4444-555555555555/session.json",
                                               "token": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"]]
        return String(decoding: try JSONEncoder().encode(body), as: UTF8.self)
    }


    func receipt(_ open: HelixOpen, _ page: ReviewPageState, sha: String, files: [NodeFile]? = nil) throws -> String {
        let files = files ?? page.payload?.data.files ?? []
        let encoded = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(files))
        let body: JSONObject = ["ok": true, "epoch": .string(open.source.epoch), "session": .string(open.lease!), "operation": .string(open.session.uuidString.lowercased()),
            "repo": .string(open.source.repo), "branch": .string(open.source.name), "expectedTip": .string(open.source.tip),
            "baseSha": .string(open.editBase!), "sha": .string(sha), "tree": .string(String(repeating: "3", count: 40)),
            "paths": .array(files.map { .string($0.path) }), "files": encoded, "history": ["sha": .string(sha), "subject": "edit a.ts", "own": true], "wrote": 1]
        return String(decoding: try JSONEncoder().encode(body), as: UTF8.self)
    }

    func nothing(_ open: HelixOpen) throws -> String {
        let body: JSONObject = ["ok": true, "nothing": true, "epoch": .string(open.source.epoch),
            "session": .string(open.lease!), "operation": .string(open.session.uuidString.lowercased())]
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

    @Test(arguments: ["missing", "script", "record", "token"]) func malformedAttachmentsCannotStartAnEditor(_ change: String) async throws {
        let (app, port) = try await app(), page = ReviewPageState.of(app)
        var body = try JSONDecoder().decode(JSONValue.self, from: Data(answer(page).utf8)).object!
        if change == "missing" { body.removeValue(forKey: "attachment") }
        else {
            var attachment = body["attachment"]!.object!
            attachment[change] = "another-attachment"
            body["attachment"] = .object(attachment)
        }
        ShipStub.answer(port, "POST", path, String(decoding: try JSONEncoder().encode(body), as: UTF8.self))
        app.keys.handle("o")
        await page.helixTask?.value
        #expect(page.helix == nil)
        #expect(!ShipStub.posts(port).contains { $0.path == commitPath })
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

    @Test func thePreparingTerminalTakesKeysAndEscapeCancelsOnlyItsSession() async throws {
        let (app, port) = try await app(), page = ReviewPageState.of(app)
        HeldLookupStub.hold(port, path)
        app.keys.handle("o")
        let oldTask = page.helixTask, old = try #require(page.helix)
        await until("the editor preparation") { HeldLookupStub.waiting(port, path) }
        let cursor = app.selected
        let terminal = HelixTerminal(frame: .zero)
        terminal.cancelPreparation = { _ = page.cancelHelixPreparation(session: old.session) }
        terminal.send(source: terminal, data: Array("b:wq\r".utf8)[...])
        #expect(page.helix?.session == old.session && app.selected == cursor && !terminal.process.running)
        terminal.send(source: terminal, data: [0x1b][...])
        #expect(page.helix == nil)
        app.keys.handle("o")
        let newTask = page.helixTask, new = try #require(page.helix)
        terminal.send(source: terminal, data: [0x1b][...])
        #expect(page.helix?.session == new.session)
        HeldLookupStub.release(port, path, try answer(page))
        await oldTask?.value
        await until("the replacement preparation") { HeldLookupStub.waiting(port, path) }
        HeldLookupStub.release(port, path, try answer(page))
        await newTask?.value
        #expect(page.helix?.session == new.session && page.helix?.dir != nil)
        #expect(!page.cancelHelixPreparation(session: new.session))
    }

    @Test func aPreparingEditorAlreadyOwnsTheKeyboard() async throws {
        let (app, port) = try await app(), page = ReviewPageState.of(app)
        HeldLookupStub.hold(port, path)
        _ = NSApplication.shared
        let frame = NSRect(x: -20000, y: -20000, width: 1100, height: 800)
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        let host = NSHostingView(rootView: RootView().environment(app))
        host.frame = NSRect(origin: .zero, size: frame.size)
        window.contentView = host
        defer { window.contentView = nil }
        app.keys.handle("o")
        let task = page.helixTask
        await until("the editor preparation") { HeldLookupStub.waiting(port, path) }
        host.layoutSubtreeIfNeeded()
        await until("the preparing terminal's keyboard focus") { window.firstResponder is HelixTerminal }
        let terminal = try #require(window.firstResponder as? HelixTerminal)
        #expect(terminal.preparing && !terminal.process.running)
        terminal.send(source: terminal, data: [0x1b][...])
        #expect(page.helix == nil)
        HeldLookupStub.release(port, path, try answer(page))
        await task?.value
    }

    @Test func writeQuitTimingObservesTheCommandBeforeTheProcessExits() {
        let terminal = HelixTerminal(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        terminal.preparing = false
        var writes = 0
        terminal.onWriteQuit = { writes += 1 }
        terminal.feed(text: "\u{1b}[\(terminal.getTerminal().rows);1H:wq")
        terminal.send(source: terminal, data: [13][...])
        #expect(writes == 1 && !terminal.process.running)
    }

    @Test func quittingShowsTheCommitInProgressUntilTheAnswerArrives() async throws {
        let (app, port) = try await app(), page = ReviewPageState.of(app)
        let open = try await ready(app, port)
        HeldLookupStub.hold(port, commitPath)
        page.finishHelix(app, session: open.session, exitCode: 0)
        #expect(page.helix == nil && app.runner.note == "committing the Helix edit to loops/\(branch)…")
        await until("the editor commit") { HeldLookupStub.waiting(port, commitPath) }
        HeldLookupStub.release(port, commitPath, try nothing(open))
        await until("the commit answer") { app.runner.runOf("review.helix.land", id)?.state == .done }
        #expect(app.runner.note == "nothing changed")
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
        HeldLookupStub.hold(port, commitPath)
        page.landHelix(app, session: open.session)
        page.landHelix(app, session: open.session)
        let replay = HelixLanding(open: open, dir: open.dir!, reader: nil)
        app.runner.dispatch("review.helix.land", via: .palette, target: id, arg: replay)
        await until("the owned editor write") { HeldLookupStub.waiting(port, commitPath) }
        let request = try #require(HeldLookupStub.lock.withLock { HeldLookupStub.pending[HeldLookupStub.key(port, commitPath)]?.first?.request })
        let body = try requestBody(request)
        #expect(body["branch"] == .string(self.branch) && body["expectedTip"] == .string(open.source.tip) && body["session"] == .string(open.lease!) && body["dir"] == nil)
        #expect(request.value(forHTTPHeaderField: "X-Stack-Write") == "1")
        #expect(request.value(forHTTPHeaderField: "X-Stack-Via") == "key")
        #expect(HeldLookupStub.lock.withLock { HeldLookupStub.pending[HeldLookupStub.key(port, commitPath)]?.count } == 1)
        #expect(app.selected == cursor && app.pane?.id == focus && page.pendingHelixReturn == nil)
        ShipStub.answer(port, "POST", "/other/edit-session", try answer(page, dir: "/tmp/other.diffbase"))
        app.keys.handle("i")
        await page.helixTask?.value
        let newer = try #require(page.helix)
        #expect(newer.source.repo == "other" && newer.dir == "/tmp/other.diffbase")
        HeldLookupStub.hold(port, "/other/edit-commit")
        page.landHelix(app, session: newer.session)
        #expect(page.pendingHelixReturn?.source.id == "other:\(self.branch)" && page.pendingHelixReturn?.session == newer.session)
        app.runner.say("newer feedback")
        HeldLookupStub.release(port, commitPath, #"{"ok":false,"err":"held refusal"}"#)
        await until("the refused original editor write") { app.runner.runOf("review.helix.land", id)?.state == .failed }
        #expect(app.runner.note == "newer feedback" && app.selected == cursor && page.helix == nil)
        #expect(page.pendingHelixReturn?.source.id == "other:\(self.branch)" && page.pendingHelixReturn?.session == newer.session)
        await until("the queued other-repo landing") { HeldLookupStub.waiting(port, "/other/edit-commit") }
        HeldLookupStub.release(port, "/other/edit-commit", try nothing(newer))
        await until("the newer editor landing") { app.runner.runOf("review.helix.land", "other:\(self.branch)")?.state == .done }
    }

    @Test func oldTerminalCallbacksCannotMoveOrQuitANewerSession() async throws {
        let (app, port) = try await app(), page = ReviewPageState.of(app)
        let old = try await ready(app, port)
        ShipStub.answer(port, "POST", commitPath, try nothing(old))
        page.landHelix(app, session: old.session)
        await until("the first landing") { app.runner.runOf("review.helix.land", id)?.state == .done }
        let new = try await ready(app, port)
        page.moveHelix(session: new.session, path: "a.ts", line: 3)
        page.moveHelix(session: old.session, path: "wrong.ts", line: 80)
        page.finishHelix(app, session: old.session, exitCode: 0)
        #expect(page.helix?.session == new.session && page.helixAt?.path == "a.ts" && page.helixAt?.line == 3)
        #expect(ShipStub.posts(port).filter { $0.path == commitPath }.count == 1)
    }

    @Test func aNonzeroExitKeepsEditsAndNeverCommits() async throws {
        let (app, port) = try await app(), page = ReviewPageState.of(app)
        let open = try await ready(app, port)
        page.finishHelix(app, session: open.session, exitCode: 1)
        #expect(page.helix == nil && app.runner.note?.contains("edits are saved in") == true)
        #expect(!ShipStub.posts(port).contains { $0.path == commitPath })
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
                HeldLookupStub.hold(port, commitPath)
                page.landHelix(app, session: open.session)
                await until("the held editor landing") { HeldLookupStub.waiting(port, commitPath) }
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
                    ? try nothing(open) : try receipt(open, page, sha: String(repeating: "2", count: 40))
                HeldLookupStub.release(port, commitPath, response)
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
        ShipStub.answer(port, "POST", commitPath, response)
        page.landHelix(app, session: open.session)
        await until("the unverified landing") { [.done, .failed].contains(app.runner.runOf("review.helix.land", id)?.state) }
        #expect(page.pendingHelixReturn == nil)
        #expect(app.runner.note?.contains("saved in /tmp/owned.diffbase") == true)
        #expect(app.runner.note?.contains("committed") != true && app.runner.note != "nothing changed")
        #expect(ShipStub.posts(port).filter { $0.path == commitPath }.count == 1)
    }

    @Test(arguments: ["epoch", "session", "operation", "repo", "branch", "expectedTip", "baseSha", "tree", "history"])
    func aReceiptMustBelongToItsExactTransaction(_ field: String) async throws {
        let (app, port) = try await app(), page = ReviewPageState.of(app)
        let open = try await ready(app, port)
        var body = try JSONDecoder().decode(JSONValue.self, from: Data(receipt(open, page, sha: String(repeating: "2", count: 40)).utf8)).object!
        body[field] = "another-transaction"
        ShipStub.answer(port, "POST", commitPath, String(decoding: try JSONEncoder().encode(body), as: UTF8.self))
        page.landHelix(app, session: open.session)
        await until("the rejected receipt") { app.runner.runOf("review.helix.land", id)?.state == .done }
        #expect(page.tip == open.source.tip && page.pendingHelixReturn == nil)
        #expect(app.runner.note?.contains("couldn't verify the edit") == true)
    }

    @Test func aCurrentReturnFollowsOnlyTheAcknowledgedCommit() async throws {
        let (app, port) = try await app(), page = ReviewPageState.of(app)
        let open = try await ready(app, port)
        page.moveHelix(session: open.session, path: "a.ts", line: 20)
        HeldLookupStub.hold(port, commitPath)
        page.landHelix(app, session: open.session)
        await until("the held editor landing") { HeldLookupStub.waiting(port, commitPath) }
        let sha = String(repeating: "2", count: 40)
        let patch = "@@ -1,3 +1,30 @@\n-one\n-two\n-three\n" + (1...30).map { "+line \($0)" }.joined(separator: "\n")
        HeldLookupStub.release(port, commitPath, try receipt(open, page, sha: sha, files: [NodeFile(path: "a.ts", add: 30, del: 3, patch: patch)]))
        await until("the acknowledged editor commit") { app.runner.runOf("review.helix.land", id)?.state == .done }
        #expect(page.tip == sha && page.pendingHelixReturn == nil)
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
        HeldLookupStub.hold(port, commitPath)
        page.landHelix(app, session: open.session)
        await until("the file edit landing") { HeldLookupStub.waiting(port, commitPath) }
        if move { app.keys.handle("j") }
        ShipStub.answer(port, "GET", "/loops/lsp/src", #"{"path":"lib/z.ts","sha":"\#(sha)","text":"one\ntwo\nnew three\nfour"}"#)
        HeldLookupStub.release(port, commitPath, try receipt(open, page, sha: sha))
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
        HeldLookupStub.hold(port, commitPath)
        HeldLookupStub.hold(port, "/loops/lsp/src")
        page.landHelix(app, session: open.session)
        await until("the switched-file landing") { HeldLookupStub.waiting(port, commitPath) }
        #expect(window.doc?.path == "lib/original.ts" && !HeldLookupStub.waiting(port, "/loops/lsp/src"))
        HeldLookupStub.release(port, commitPath, try receipt(open, page, sha: sha))
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
        HeldLookupStub.hold(port, commitPath)
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
        #expect(!HeldLookupStub.waiting(port, commitPath) && page.pendingHelixReturn == nil)
        #expect(app.runner.note == "newer feedback")
        #expect(ShipStub.posts(port).filter { $0.path == commitPath }.isEmpty)
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
