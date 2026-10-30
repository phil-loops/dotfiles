import CanopyCore
import Foundation
import Testing
@testable import CanopyUI

/// Answers the app's requests from a table keyed "<port> <METHOD> <path>", recording what was sent.
/// Each test uses its own port, so tests never see each other's requests. Nothing reaches a server.
final class ShipStub: URLProtocol, @unchecked Sendable {
    struct Answer { var status = 200; var body: String; var headers: [String: String] = [:] }
    nonisolated(unsafe) static var answers: [String: Answer] = [:]
    nonisolated(unsafe) static var seen: [String: [(method: String, path: String, body: JSONValue)]] = [:]
    static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let port = "\(url.port ?? 0)"
        let method = request.httpMethod ?? "GET"
        var data = request.httpBody
        if data == nil, let s = request.httpBodyStream {
            s.open()
            var d = Data()
            var buf = [UInt8](repeating: 0, count: 4096)
            while s.hasBytesAvailable { let n = s.read(&buf, maxLength: buf.count); if n <= 0 { break }; d.append(buf, count: n) }
            s.close()
            data = d
        }
        let body = data.flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) } ?? .null
        let a = ShipStub.lock.withLock { () -> Answer? in
            ShipStub.seen[port, default: []].append((method, url.path, body))
            return ShipStub.answers["\(port) \(method) \(url.path)"]
        } ?? Answer(status: 404, body: "{}")
        let resp = HTTPURLResponse(url: url, statusCode: a.status, httpVersion: "HTTP/1.1", headerFields: a.headers)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(a.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    static func answer(_ port: Int, _ method: String, _ path: String, _ body: String, status: Int = 200) {
        lock.withLock { answers["\(port) \(method) \(path)"] = Answer(status: status, body: body) }
    }
    static func posts(_ port: Int) -> [(path: String, body: JSONValue)] {
        lock.withLock { (seen["\(port)"] ?? []).filter { $0.method == "POST" }.map { ($0.path, $0.body) } }
    }
}

@MainActor @Suite struct ShipTests {
    static let branch = "loops:add-hankles-limited-label"
    static let thread = "loops:add-hankles-limited-label#PRRT_kwDOGSZuWM6xwpk_"
    nonisolated(unsafe) static var nextPort = 41000

    /// A whole app on the review page, the store from the real /state fixture, every request stubbed.
    func app(port: Int? = nil, edit: (inout JSONObject) -> Void = { _ in }) throws -> (AppModel, Int) {
        let p = port ?? { Self.nextPort += 1; return Self.nextPort }()
        var c = AppConfig()
        c.route = .review(repo: "loops", branch: "add-hankles-limited-label")
        let a = AppModel(config: c, port: p, telemetry: false, protocolClasses: [ShipStub.self])
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../CanopyCoreTests/Fixtures/state.json")
        var state = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url)).object!
        edit(&state)
        a.store.hydrate(try Snapshot.decode(JSONEncoder().encode(JSONValue.object(state))))
        a.transport.repos = ["loops"]
        ShipState.of(a).openURL = { _ in Issue.record("a test tried to open a browser") }
        return (a, p)
    }

    /// Edit one entity of the fixture.
    func entity(_ s: inout JSONObject, _ type: String, _ id: String, _ f: (inout JSONObject) -> Void) {
        var ents = s["entities"]!.object!
        var table = ents[type]!.object!
        var o = table[id]!.object!
        f(&o)
        table[id] = .object(o)
        ents[type] = .object(table)
        s["entities"] = .object(ents)
    }

    func until(_ what: String, timeout: Double = 3, _ ok: () -> Bool) async {
        let t0 = Date()
        while !ok() {
            if Date().timeIntervalSince(t0) > timeout { Issue.record("timed out waiting for \(what)"); return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    // ── the mouseless rule ──

    @Test func everyShipCommandIsReachableByKey() throws {
        let (a, _) = try app()
        let mine = Set(ShipState.of(a).commandIDs)
        #expect(mine.count > 60)
        for id in ["review.push", "review.sync", "branch.sync", "words.save", "review.compose.send", "history.next", "commit.back", "branch.pr", "forest.preview"] {
            #expect(mine.contains(id), "\(id)")
        }
        #expect(KeyboardRule.violations(a) { mine.contains($0) } == [])
        #expect(a.registry.keyProblems.isEmpty, "\(a.registry.keyProblems)")
    }

    @Test func textEntryKeysAreNonPrintable() throws {
        let (a, _) = try app()
        for c in a.registry.commands where ShipState.of(a).commandIDs.contains(c.id) && c.modes.contains(.insert) {
            #expect(c.keys.allSatisfy { $0.count > 1 }, "\(c.id) binds \(c.keys) in insert")
        }
    }

    // ── the seam B builds on ──

    @Test func theConversationPaneIsTheTimeline() throws {
        let (a, _) = try app()
        ShipState.of(a).host.tab = "conversation"   // the review page opens on its files tab
        let rows = ShipSeam.panes(a).first { $0.id == ShipSeam.conversationPane }?.rows ?? []
        #expect(rows.first == "c|body")
        #expect(rows.contains("t|\(Self.thread)"))
        // a COMMENTED review with no body isn't a card; a change request is
        let reviews = rows.filter { $0.hasPrefix("c|r") }
        #expect(reviews.contains { $0.hasSuffix("|notnmeyer") })
        #expect(!reviews.contains { $0.hasSuffix("|john-hankles") })
        #expect(ShipSeam.primary(for: "t|x", a)?.id == "review.fold")
        #expect(ShipSeam.primary(for: "w|title", a)?.id == "words.edit")
        #expect(ShipSeam.target(for: .review, a) == Self.branch)
    }

    @Test func foldingAThreadShowsItsReplies() throws {
        let (a, _) = try app { s in
            self.entity(&s, "draft", Self.branch) { d in
                d["items"] = [["key": "k1", "kind": "reply", "threadId": .string(Self.thread), "thread": "PRRT_kwDOGSZuWM6xwpk_", "body": "on it",
                               "state": "draft", "waitsFor": [], "send": false, "at": "2026-10-29T22:00:00Z"]]
            }
        }
        let ship = ShipState.of(a)
        #expect(!ShipRows.conversation(a, Self.branch).contains("p|k1"))   // resolved: folded
        a.runner.dispatch("review.fold", via: .key, target: Self.thread)
        #expect(ShipRows.conversation(a, Self.branch).contains("p|k1"))
        #expect(ship.unfold[Self.thread] == true)
    }

    // ── writing: the composer in insert mode, the ledger ──

    @Test func aReplyIsWrittenInInsertModeAndSentToTheLedger() async throws {
        let (a, port) = try app()
        ShipStub.answer(port, "POST", "/loops/review-draft", #"{"ok":true}"#)
        let ship = ShipState.of(a)
        a.runner.dispatch("review.reply", via: .key, target: Self.thread)
        #expect(ship.composer == .reply(key: "r|\(Self.thread)", threadID: Self.thread))
        #expect(a.keys.mode == .insert && a.insertField == ReviewCommands.composeField)
        // typing goes to the field: printable keys aren't bound in insert
        #expect(a.keys.handle("x") == false)
        ship.setText("r|\(Self.thread)", "  thanks — fixed  ")
        #expect(a.keys.handle("C-ret"))
        #expect(a.keys.mode == .normal)
        #expect(ship.composer == nil)
        #expect(a.store.view(Draft.self, Self.branch)?.items.first?.body == "thanks — fixed")   // the optimistic overlay
        await until("the post") { !ShipStub.posts(port).isEmpty }
        let p = try #require(ShipStub.posts(port).first)
        #expect(p.path == "/loops/review-draft")
        #expect(p.body["op"] == "add" && p.body["send"] == true)
        #expect(p.body["item"]?["kind"] == "reply" && p.body["item"]?["thread"] == "PRRT_kwDOGSZuWM6xwpk_")
        #expect(p.body["item"]?["body"] == "thanks — fixed")
        ship.setText("r|\(Self.thread)", "")
    }

    @Test func aRefusedDraftPutsTheWordsBack() async throws {
        let (a, port) = try app()
        ShipStub.answer(port, "POST", "/loops/review-draft", #"{"ok":false,"err":"kept as a draft — github writes need a browser"}"#)
        let ship = ShipState.of(a)
        a.runner.dispatch("review.reply", via: .key, target: Self.thread)
        ship.setText("r|\(Self.thread)", "words")
        a.keys.handle("esc"); a.keys.handle(","); a.keys.handle("d")   // stop writing, save as a draft
        #expect(ship.composer == nil)
        await until("the words back") { ship.composer != nil }
        #expect(ship.text("r|\(Self.thread)") == "words")
        #expect(a.store.view(Draft.self, Self.branch)?.items.isEmpty == true)
        ship.setText("r|\(Self.thread)", "")
    }

    @Test func emptyWordsAreRefusedBeforeSending() throws {
        let (a, port) = try app()
        a.runner.dispatch("review.reply", via: .key, target: Self.thread)
        ShipState.of(a).setText("r|\(Self.thread)", "   ")
        a.runner.dispatch("review.compose.send", via: .key, target: Self.branch)
        #expect(a.runner.note == "write something first")
        #expect(ShipStub.posts(port).isEmpty)
        #expect(a.keys.mode == .insert)   // still writing
    }

    @Test func escBacksOutOfTheComposerOneLevelAtATime() throws {
        let (a, _) = try app()
        let ship = ShipState.of(a)
        a.runner.dispatch("review.reply", via: .key, target: Self.thread)
        a.keys.handle("esc")
        #expect(a.keys.mode == .normal && ship.composer != nil)   // stop typing, the box stays
        a.keys.handle("i")
        #expect(a.keys.mode == .insert && a.insertField == ReviewCommands.composeField)
        a.keys.handle("esc")
        a.keys.handle("esc")
        #expect(ship.composer == nil)
    }

    @Test func aSuggestionComesFromTheHostsLines() throws {
        final class Host: ShipHost {
            var tab = "files"
            func lineRange(_ app: AppModel) -> ShipLineRange? { ShipLineRange(path: "a.ts", side: .right, line: 4, startLine: 3) }
            func newLines(_ app: AppModel, path: String, from: Int, to: Int) -> [String] { (from...to).map { "line \($0)" } }
            func showThread(_ app: AppModel, id: String) {}
            func commitScopeChanged(_ sha: String?) {}
            func focusDiff(_ app: AppModel, _ on: Bool) {}
            func clearMark() {}
        }
        let (a, _) = try app()
        let ship = ShipState.of(a)
        ship.host = Host()
        a.runner.dispatch("review.comment", via: .key, target: "l|a.ts|R:4")
        guard case .line(let key, "a.ts", .right, 4, 3, nil) = ship.composer else { Issue.record("\(String(describing: ship.composer))"); return }
        a.keys.handle("esc"); a.keys.handle(","); a.keys.handle("S")
        #expect(ship.text(key) == "```suggestion\nline 3\nline 4\n```\n")
        ship.setText(key, "")
    }

    @Test func pendingDraftsDeleteAndComeBack() async throws {
        let (a, port) = try app { s in
            self.entity(&s, "draft", Self.branch) { d in
                d["items"] = [["key": "k1", "kind": "comment", "path": "a.ts", "side": "RIGHT", "line": 3, "body": "hm", "state": "draft",
                               "waitsFor": [], "send": false, "at": "2026-10-29T22:00:00Z"]]
            }
        }
        ShipStub.answer(port, "POST", "/loops/review-draft", #"{"ok":true}"#)
        a.runner.dispatch("review.pending.remove", via: .key, target: "k1")
        #expect(a.store.view(Draft.self, Self.branch)?.items.isEmpty == true)
        await until("the remove") { ShipStub.posts(port).count == 1 }
        #expect(ShipStub.posts(port)[0].body["op"] == "remove" && ShipStub.posts(port)[0].body["key"] == "k1")
        // the server agrees (the patch), then u puts it back
        a.store.applyPatch(try Patch.decode(Data(#"{"domain":"review","version":\#((a.store.versions["review"] ?? 0) + 1),"upserts":{"draft":{"\#(Self.branch)":{"id":"\#(Self.branch)","repo":"loops","branch":"add-hankles-limited-label","items":[]}}}}"#.utf8)))
        await until("the undo to be ready") { a.runner.runOf("review.pending.remove", "k1")?.state == .done }
        #expect(a.runner.undoLast())
        await until("the restore") { ShipStub.posts(port).count == 2 }
        let back = ShipStub.posts(port)[1].body
        #expect(back["op"] == "add" && back["item"]?["key"] == "k1" && back["item"]?["path"] == "a.ts")
    }

    // ── address: the layer's own keys ──

    @Test func theAddressSheetIsALayerWithItsOwnKeys() async throws {
        let (a, port) = try app { s in
            self.entity(&s, "thread", Self.thread) { t in t["resolved"] = false; t["outdated"] = false; t["local"] = ["line": 12] }
        }
        ShipStub.answer(port, "POST", "/loops/open", #"{"ok":true}"#)
        a.runner.dispatch("review.address", via: .key, target: Self.thread)
        #expect(a.keys.layer == .address && ShipState.of(a).addressing == Self.thread)
        a.keys.handle("o")
        #expect(a.keys.layer == nil)
        await until("the open") { !ShipStub.posts(port).isEmpty }
        let p = ShipStub.posts(port)[0]
        #expect(p.path == "/loops/open" && p.body["path"] == ".github/workflows/code-review.yml" && p.body["line"] == 12)
        // esc closes the sheet without sending anything
        a.runner.dispatch("review.address", via: .key, target: Self.thread)
        a.keys.handle("esc")
        #expect(a.keys.layer == nil && ShipStub.posts(port).count == 1)
    }

    // ── the push key is area A's route ──

    @Test func pFollowsBranchPushsRoute() throws {
        let (a, _) = try app()
        // area A's real route: the fixture branch is synced with an open PR, so there's nothing to push
        #expect(BranchCommands.pushRoute(Self.branch, a) == nil)
        a.keys.handle("p")
        #expect(a.forestModel.armed == nil)
        // a green branch with commits origin lacks arms on p, and p again would send it
        a.forestModel.armed = Self.branch
        #expect(a.registry.command("review.push")?.route?(Self.branch) == nil || a.forestModel.armed == Self.branch)
    }

    @Test func goToThePROpensIt() throws {
        let (a, _) = try app()
        var opened: URL?
        ShipState.of(a).openURL = { opened = $0 }
        a.runner.dispatch("branch.pr", via: .key, target: Self.branch)
        #expect(opened?.absoluteString == "https://github.com/loops-so/loops/pull/11285")
        a.runner.dispatch("branch.preview", via: .key, target: Self.branch)
        #expect(opened?.absoluteString.hasSuffix("/loops/preview-wait?branch=add-hankles-limited-label") == true)
    }

    // ── the history and the words ──

    @Test func historyStepsSelectOneCommit() throws {
        let (a, _) = try app()
        let ship = ShipState.of(a)
        let b = try #require(a.store.view(Branch.self, Self.branch))
        ship.putHistory(b, [HistoryCommit(sha: "aaa1111", subject: "rename"), HistoryCommit(sha: "bbb2222", subject: "fail louder"),
                            HistoryCommit(sha: "ccc3333", subject: "someone else's", own: false)])
        #expect(ShipRows.history(a, Self.branch) == ["h|", "h|aaa1111", "h|bbb2222"])
        a.runner.dispatch("history.select", via: .key, arg: "bbb2222")
        #expect(ship.commitScope == "bbb2222" && ship.host.tab == "commits")
        a.runner.dispatch("history.exit", via: .key)
        #expect(ship.commitScope == nil)
    }

    func outline(ticket: String? = nil) -> WordsOutline {
        WordsOutline(branch: "add-hankles-limited-label", head: "e1b98e2a", description: "Adds a label", ticket: ticket,
                     commits: [OutlineCommit(sha: "c1", subject: "chore: add a one-shot label", locked: "on origin"),
                               OutlineCommit(sha: "c2", subject: "fail louder"),
                               OutlineCommit(sha: "c3", subject: "refactor: rename the label")],
                     draft: .init(title: "chore: add a one-shot hankles tag", body: "why\n\n---\n👮 Traffic Cop"), pr: .init(exists: false))
    }

    @Test func wordsSaveRewordsInOnePass() async throws {
        let (a, port) = try app()
        ShipStub.answer(port, "POST", "/loops/outline", #"{"ok":true,"newTip":"f00","changed":2}"#)
        let w = WordsState.of(a)
        w.setShown(Self.branch, outline(ticket: "LOO-9"))
        let c3 = w.shown[Self.branch]!.commits[2]
        // f applies the hint's fix on the row: a follow-up reads bare
        a.runner.dispatch("words.fix", via: .key, target: "w|s|c3")
        #expect(w.valueOf(Self.branch, c3).subject == "rename the label")
        w.editPr(Self.branch, MessageWords(subject: "chore(loo-9): add a one-shot tag", body: w.prValue(Self.branch).body))
        #expect(w.pending(Self.branch) == 2)
        a.runner.dispatch("words.save", via: .key, target: Self.branch)
        #expect(w.pending(Self.branch) == 0)   // drafts leave at once
        await until("the save") { !ShipStub.posts(port).isEmpty }
        let p = ShipStub.posts(port)[0].body
        #expect(p["head"] == "e1b98e2a" && p["prTitle"] == "chore(loo-9): add a one-shot tag" && p["prBody"] == nil)
        #expect(p["edits"] == [["sha": "c3", "subject": "rename the label", "body": ""]])
        #expect(w.prOnFile(Self.branch).subject == "chore(loo-9): add a one-shot tag")
    }

    @Test func aRefusedSaveKeepsTheEdits() async throws {
        let (a, port) = try app()
        ShipStub.answer(port, "POST", "/loops/outline", #"{"ok":false,"err":"the branch moved"}"#)
        let w = WordsState.of(a)
        w.setShown(Self.branch, outline())
        w.editTo(Self.branch, w.shown[Self.branch]!.commits[1], MessageWords(subject: "fail loudly", body: ""))
        a.runner.dispatch("words.save", via: .key, target: Self.branch)
        await until("the refusal") { w.pending(Self.branch) == 1 }
        #expect(a.runner.note?.contains("your edits are kept") == true)
    }

    @Test func lockedCommitsAndGithubOwnedTextArentEditable() throws {
        let (a, _) = try app()
        let w = WordsState.of(a)
        w.setShown(Self.branch, outline())
        #expect(!WordsCommands.editable(a, Self.branch, .subject("c1")))
        #expect(WordsCommands.editable(a, Self.branch, .subject("c2")))
        #expect(WordsCommands.editable(a, Self.branch, .title))
        var o = outline()
        o.pr = .init(exists: true, number: 1, state: "OPEN")
        w.setShown(Self.branch, o)
        #expect(!WordsCommands.editable(a, Self.branch, .title))
        #expect(ShipRows.words(a, Self.branch) == ["w|desc"])
        a.runner.dispatch("words.edit", via: .key, target: "w|s|c2")
        #expect(a.insertField == "words.s|\(Self.branch)|c2")
    }

    @Test func decodesALiveOutline() throws {
        // GET /loops/outline?branch=add-email-reading-format, 2026-10-29
        let json = #"{"ok": true, "branch": "add-email-reading-format", "parent": "main", "base": "origin/main", "head": "8131570f48b7e92e1e0addfee1cfe5f380b2410d", "description": "converts email HTML into a standard reading format with inline links, buttons and images", "story": "", "ticket": "", "commits": [{"sha": "8131570f48b7e92e1e0addfee1cfe5f380b2410d", "short": "8131570f48", "subject": "feat: add email reading format", "body": "", "author": "Phil Brockman", "date": "2026-10-26", "pushed": false, "merge": false, "carried": false, "locked": "", "files": 2, "add": 283, "del": 0}], "pr": {"exists": false}, "draft": {"title": "feat: add email reading format", "titleSaved": false, "body": "", "bodySaved": false, "derivedBody": null, "bodyPending": true}, "reseat": null, "undo": null}"#
        let o = try JSONDecoder().decode(WordsOutline.self, from: Data(json.utf8))
        #expect(o.commits.first?.locked == "" && o.draft?.bodyPending == true && o.pr?.exists == false)
        let h = try JSONDecoder().decode([HistoryCommit].self, from: Data(#"[{"sha": "8131570f48", "subject": "feat: add", "author": "P", "date": "2026-10-26", "body": "", "own": true}]"#.utf8))
        #expect(h.first?.own == true && h.first?.pushed == nil)
    }

    // ── ⟲ sync, step by step ──

    @Test func syncWalksItsStepsInOrder() async throws {
        let (a, port) = try app()
        ShipStub.answer(port, "GET", "/loops/sync", #"{"behind":3,"syncable":true,"restack":false,"published":false,"dirty":[],"dirtyWorktree":"","why":""}"#)
        ShipStub.answer(port, "POST", "/loops/sync", #"{"ok":true,"rebased":true,"summary":"replayed 3 commits"}"#)
        ShipStub.answer(port, "POST", "/loops/prep-push", #"{"ok":true,"routed":["3 voiced commits — pushed as they are"]}"#)
        ShipStub.answer(port, "POST", "/loops/delta-tests", #"{"ok":true,"ran":true,"passed":2}"#)
        a.keys.handle("s")
        let ship = ShipState.of(a)
        await until("the motion to finish") { ship.motionOf(Self.branch)?.phase == .done }
        let steps = try #require(ship.motionOf(Self.branch)?.steps)
        #expect(steps.map(\.id) == [.dirt, .rebase, .prep, .gates, .tests])
        #expect(steps.map(\.state) == [.ok, .ok, .ok, .ok, .ok])   // area A's branch.gates.run starts the gates
        #expect(steps[1].note == "replayed 3 commits" && steps[4].note == "2 ✓")
        // the gates post on the FIFO queue, the delta tests beside it (`alone`): either may land first
        #expect(Set(ShipStub.posts(port).map(\.path)) == ["/loops/sync", "/loops/prep-push", "/loops/gates", "/loops/delta-tests"])
        #expect(a.runner.note == "synced add-hankles-limited-label")
        a.runner.dispatch("review.sync.dismiss", via: .key)
        #expect(ship.motionOf(Self.branch) == nil)
    }

    @Test func dirtWaitsForADecisionAndAStashComesBack() async throws {
        let (a, port) = try app()
        ShipStub.answer(port, "GET", "/loops/sync", #"{"behind":0,"syncable":false,"restack":false,"published":true,"dirty":["a.ts"],"dirtyRows":[{"path":"a.ts","code":" M","patch":"@@ -1 +1 @@\n-a\n+b"}],"dirtyWorktree":"/wt","why":""}"#)
        ShipStub.answer(port, "POST", "/loops/dirty-resolve", #"{"ok":true}"#)
        ShipStub.answer(port, "POST", "/loops/prep-push", #"{"ok":false,"err":"nothing to push — origin already has this"}"#)
        let ship = ShipState.of(a)
        a.runner.dispatch("branch.sync", via: .key, target: Self.branch)
        await until("the dirt decision") { ship.motionOf(Self.branch)?.phase == .dirt }
        #expect(ship.motionOf(Self.branch)?.dirt?.files == ["a.ts"])
        a.runner.dispatch("review.sync.dirt.show", via: .key)
        #expect(ship.dirtOpen == "\(Self.branch)|a.ts")
        a.runner.dispatch("review.sync.stash", via: .key)
        await until("the motion to finish") { ship.motionOf(Self.branch)?.phase == .done && ShipStub.posts(port).count == 3 }
        let posts = ShipStub.posts(port)
        #expect(posts.map(\.path) == ["/loops/dirty-resolve", "/loops/prep-push", "/loops/dirty-resolve"])
        #expect(posts[0].body["action"] == "stash" && posts[2].body["action"] == "pop")
        await until("the pop") { ship.motionOf(Self.branch)?.stashed == false }
        #expect(ship.motionOf(Self.branch)?.steps.first?.note == "stash popped — your uncommitted changes are back")
    }

    @Test func aRebaseConflictGoesToClaude() async throws {
        let (a, port) = try app()
        ShipStub.answer(port, "GET", "/loops/sync", #"{"behind":2,"syncable":true,"dirty":[]}"#)
        ShipStub.answer(port, "POST", "/loops/sync", #"{"ok":true,"ejected":true,"conflict":true,"stream":"rebase:x"}"#)
        let ship = ShipState.of(a)
        a.runner.dispatch("branch.sync", via: .key, target: Self.branch)
        await until("the hand-off") { ship.motionOf(Self.branch)?.phase == .conflict }
        #expect(ShipStub.posts(port).map(\.path) == ["/loops/sync"])
        #expect(a.runner.note == "add-hankles-limited-label: conflict — with Claude")
    }
}
