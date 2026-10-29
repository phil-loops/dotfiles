import CanopyCore
import Foundation
import Testing
@testable import CanopyUI

/// Answers the tutor's requests from a per-path table and records what was sent. Never the live
/// server: every learning write (and every turn) would touch Phil's real graph.
final class TutorStub: URLProtocol, @unchecked Sendable {
    struct Answer { var status = 200; var body: String; var type = "application/json" }
    nonisolated(unsafe) static var answers: [String: Answer] = [:]
    nonisolated(unsafe) static var seen: [(path: String, query: String, body: JSONValue?)] = []
    static let lock = NSLock()

    static func reset(_ a: [String: Answer]) { lock.withLock { answers = a; seen = [] } }
    static func sent(_ path: String) -> [JSONValue?] { lock.withLock { seen.filter { $0.path == path }.map(\.body) } }
    static func queries(_ path: String) -> [String] { lock.withLock { seen.filter { $0.path == path }.map(\.query) } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        var body: JSONValue?
        if let s = request.httpBodyStream {
            s.open()
            var d = Data()
            var buf = [UInt8](repeating: 0, count: 4096)
            while s.hasBytesAvailable { let n = s.read(&buf, maxLength: buf.count); if n <= 0 { break }; d.append(buf, count: n) }
            s.close()
            body = try? JSONDecoder().decode(JSONValue.self, from: d)
        } else if let d = request.httpBody {
            body = try? JSONDecoder().decode(JSONValue.self, from: d)
        }
        let a = TutorStub.lock.withLock { TutorStub.seen.append((url.path, url.query ?? "", body)); return TutorStub.answers[url.path] } ?? Answer(status: 404, body: "{}")
        let resp = HTTPURLResponse(url: url, statusCode: a.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": a.type])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(a.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// A trimmed /learning-state in the live shape (2026-10-29): extra top-level keys the page ignores.
let learningFixture = #"""
{"concepts": {
  "one-runner-per-tick": {"name": "One runner per tick", "statement": "N copies of a scheduler share one schedule.", "kind": "principle",
    "builds_on": [], "analogs": ["dispatch-coalescing"], "code": [{"path": "packages/croon/lock.ts", "ref": "abc", "lines": [3, 9]}],
    "topics": ["croon-job-locks"], "created": "2026-06-26", "id": "one-runner-per-tick",
    "mastery": {"depth": 2, "assisted": 2, "level": "explain", "held": 0, "held_level": "", "evidence": 1, "last": "2026-06-26", "due": true,
      "reason": "shown unaided, last 125 days ago", "open_miss": "", "miss_confidence": "", "contrast": "", "misses": 0, "overdue": 121},
    "built_on_by": ["dead-holder-blocks-forever"], "blocked_by": []},
  "dead-holder-blocks-forever": {"name": "A dead holder blocks forever", "statement": "A crashed holder never releases.", "kind": "principle",
    "builds_on": ["one-runner-per-tick"], "analogs": [], "code": [], "topics": ["croon-job-locks"], "id": "dead-holder-blocks-forever",
    "mastery": {"depth": 0, "assisted": 1, "level": "", "held": 0, "evidence": 1, "last": "", "due": true, "reason": "open miss",
      "open_miss": "e2", "miss_confidence": "high"}, "built_on_by": [], "blocked_by": ["one-runner-per-tick"]},
  "lock-ttl": {"name": "Lock TTL", "statement": "A lock expires.", "kind": "convention", "builds_on": [], "analogs": [], "code": [],
    "topics": ["croon-job-locks"], "id": "lock-ttl", "mastery": {"depth": 0, "assisted": 0, "level": "", "evidence": 0, "last": "", "due": false,
      "reason": "", "open_miss": ""}, "built_on_by": []}
 },
 "topics": {"croon-job-locks": {"title": "Distributed job locks (croon)", "source": "croon PR #9273",
   "stages": [{"name": "Why a lock", "concepts": ["one-runner-per-tick", "dead-holder-blocks-forever"]}, {"name": "Leases", "concepts": ["lock-ttl"]}],
   "created": "2026-06-26", "updated": "2026-10-21", "id": "croon-job-locks", "progress": {"held": 0, "shown": 1, "total": 3}}},
 "due": ["dead-holder-blocks-forever", "one-runner-per-tick"],
 "systems": {}, "standards": {}, "standards_due": [],
 "questions": [{"id": "q1", "text": "Why a token?", "concept": "one-runner-per-tick", "topic": "croon-job-locks", "asked": "2026-10-21", "status": "open"},
               {"id": "q2", "text": "Old one", "concept": "one-runner-per-tick", "topic": "", "asked": "2026-10-01", "status": "answered"}],
 "calibration": [],
 "evidence": [{"id": "ev1", "concept": "one-runner-per-tick", "level": "explain", "credit": "unaided", "outcome": "hit", "note": "fast", "at": "2026-06-26",
               "topic": "croon-job-locks", "session": "S1"},
              {"id": "ev2", "concept": "dead-holder-blocks-forever", "level": "predict", "credit": "scaffolded", "outcome": "miss", "note": "", "at": "2026-06-27",
               "topic": "croon-job-locks", "session": "seed", "confidence": "high"}],
 "levels": [], "credits": [], "confidences": [], "rungs": [], "sources": [], "today": "2026-10-29"}
"""#

@MainActor @Suite(.serialized) struct TutorTests {
    func app(_ route: Route = .tutor(session: nil)) -> (AppModel, TutorState) {
        var c = AppConfig()
        c.route = route
        let a = AppModel(config: c, port: 1, telemetry: false)
        let t = TutorArea.state(a)
        t.sessionsFile = nil
        t.sessions = []
        t.transport = Transport(base: URL(string: "http://stub.test")!, protocolClasses: [TutorStub.self])
        t.retryDelay = .milliseconds(1)
        t.maxTries = 2
        t.learn = try! JSONDecoder().decode(LearnState.self, from: Data(learningFixture.utf8))
        return (a, t)
    }

    func session(_ t: TutorState, id: String = "S1", msgs: [Msg], topic: String? = "croon-job-locks") {
        t.sessions.insert(Session(id: id, target: "croon locks", created: 1, sessionId: "claude-1", msgs: msgs, topic: topic), at: 0)
    }

    /// Wait for the main actor's background work (a Task) to land.
    func settle(_ ok: @escaping () -> Bool) async {
        for _ in 0..<200 where !ok() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func everyTutorCommandIsReachableByKey() {
        let (a, _) = app()
        #expect(KeyboardRule.violations(a) { $0.hasPrefix("tutor.") || $0 == "find.concept" }.isEmpty)
        #expect(a.registry.keyProblems.isEmpty, "\(a.registry.keyProblems)")
    }

    @Test func theLearningStateDecodesInItsLiveShape() throws {
        let (_, t) = app()
        let l = try #require(t.learn)
        #expect(l.concepts.count == 3)
        #expect(l.concepts["dead-holder-blocks-forever"]?.mastery.miss_confidence == "high")
        #expect(l.topics["croon-job-locks"]?.progress.shown == 1)
        #expect(t.openQuestions.map(\.id) == ["q1"])
    }

    @Test func theHomeIsPanesOfRows() {
        let (a, t) = app()
        session(t, msgs: [.tutor("What next?")])
        #expect(a.panes.map(\.id) == ["due", "topics", "questions", "sessions"])
        #expect(a.rows == ["c:dead-holder-blocks-forever", "c:one-runner-per-tick"])
        #expect(TutorRows.topics(t) == ["tp:croon-job-locks", "tc:croon-job-locks|one-runner-per-tick", "tc:croon-job-locks|dead-holder-blocks-forever", "tc:croon-job-locks|lock-ttl"])
        #expect(a.liveScopes() == [.concept, .tutor, .global])
        #expect(a.target(for: .concept) == "dead-holder-blocks-forever")
        a.keys.handle("C-w"); a.keys.handle("j")
        #expect(a.pane?.id == "topics")
        #expect(a.liveScopes().first == .topic)
        #expect(a.target(for: .topic) == "croon-job-locks")
        a.keys.handle("j")
        #expect(a.target(for: .concept) == "one-runner-per-tick", "a chip in a topic is its concept")
    }

    @Test func retOpensTheConceptDrawerAndEscBacksOut() {
        let (a, t) = app()
        a.keys.handle("j")
        a.keys.handle("ret")
        #expect(t.drawer == "one-runner-per-tick")
        #expect(a.pane?.id == "drawer")
        #expect(a.rows.first == "dh:one-runner-per-tick")
        #expect(a.rows.contains("dl:0:dead-holder-blocks-forever") && a.rows.contains("dl:1:dispatch-coalescing"), "builds-on / built-on-by / analogs are rows")
        #expect(a.rows.contains("dc:0") && a.rows.contains("q:q1") && a.rows.contains("ask") && a.rows.contains("e:ev1"))
        // ret on a link opens that concept
        a.setCursor("dl:0:dead-holder-blocks-forever")
        a.keys.handle("ret")
        #expect(t.drawer == "dead-holder-blocks-forever")
        // the credit's keys: m toggles hit/miss as a write (the write itself is checked below)
        a.setCursor("e:ev2")
        #expect(a.liveScopes().first == .credit)
        a.keys.handle("esc")
        #expect(t.drawer == nil)
        #expect(a.pane?.id == "due", "focus returns to where the drawer opened from")
        a.keys.handle("esc")
        #expect(a.runner.note == "esc · nothing here" || a.runner.note == "nothing to close")
    }

    @Test func findConceptOpensItsDrawerOnTheHome() {
        let (a, t) = app(.forests)
        a.runner.dispatch("find.concept", via: .menu, arg: "lock-ttl")
        #expect(a.router.route == .tutor(session: nil))
        #expect(t.drawer == "lock-ttl")
        #expect(a.pane?.id == "drawer")
    }

    @Test func iWritesInWhicheverBoxIsOnScreen() {
        let (a, t) = app()
        a.keys.handle("i")
        #expect(a.keys.mode == .insert && a.insertField == "tutor.target")
        #expect(!a.keys.handle("j"), "typing goes to the field")
        a.keys.handle("esc")
        t.openDrawer("lock-ttl")
        a.keys.handle("i")
        #expect(a.insertField == "tutor.question")
        a.keys.handle("esc"); a.keys.handle("esc")
        session(t, msgs: [.tutor("Q?")])
        a.go(.tutor(session: "S1"))
        a.keys.handle("i")
        #expect(a.insertField == "tutor.draft")
    }

    @Test func aSessionIsTheTurnTheMapAndThePinnedCode() async {
        let (a, t) = app()
        let text = """
        Look here.
        ```tutor-rung
        {"concept": "one-runner-per-tick", "level": "predict", "rung": "predict", "confidence": true}
        ```
        ```tutor-pin
        {"path": "packages/croon/lock.ts", "ref": "abc", "lines": [2, 3]}
        ```
        Which runs?
        ```tutor-options
        ["the first", "both"]
        ```
        """
        session(t, msgs: [.tutor("Earlier?"), .me("yes"), .tutor(text)])
        TutorStub.reset(["/tutor-src": .init(body: #"{"path":"packages/croon/lock.ts","ref":"abc","text":"import x from 'y'\nexport const lock = Locks.take(1)\nreturn\n"}"#)])
        a.go(.tutor(session: "S1"))
        #expect(a.pane?.id == "turn")
        #expect(a.rows == ["hist", "x:2:1:0", "x:2:3:0", "x:2:5:0", "x:2:5:1"])
        #expect(t.here == "one-runner-per-tick")
        #expect(t.wantsConfidence)
        #expect(a.liveScopes().contains(.session))

        // ret on the pin shows its code; the code pane's lines are rows
        a.setCursor("x:2:3:0")
        a.keys.handle("ret")
        #expect(t.pin == Pin(path: "packages/croon/lock.ts", ref: "abc", lines: [2, 3]))
        await settle { t.code != nil }
        #expect(t.code?.text?.hasPrefix("import") == true)
        #expect(TutorStub.queries("/tutor-src") == ["path=packages%2Fcroon%2Flock.ts&ref=abc"])
        #expect(a.panes.map(\.id).contains("code"))
        a.focus(pane: "code")
        a.setCursor("L:2")
        #expect(TutorRows.codeCursor(a, t) == 2)
        #expect(TutorLookup.firstName("export const lock = Locks.take(1)")! == (13, nil))
        #expect(TutorLookup.firstName("x = Locks.take(1)")!.character == 0)
        #expect(TutorLookup.firstName("  Locks.take(1)")! == (2, 8))

        // ret on an option puts it in the box and starts writing
        a.focus(pane: "turn")
        a.setCursor("x:2:5:1")
        a.keys.handle("ret")
        #expect(t.draft == "both" && a.insertField == "tutor.draft")
        // ⌥2 rates while typing; the first ret without a rating would flag the chips instead
        a.keys.handle("A-2")
        #expect(t.confidence == "medium")
        a.keys.handle("esc")

        // the earlier rungs fold
        a.setCursor("hist")
        a.keys.handle("ret")
        #expect(t.historyOpen)
        #expect(a.rows.contains("r:0"))
        a.setCursor("r:0")
        a.keys.handle("ret")
        #expect(t.expanded == 0)

        // h goes home
        a.keys.handle("h")
        #expect(a.router.route == .tutor(session: nil))
    }

    @Test func sendWithoutARatingFlagsTheChipsOnceThenSends() async {
        let (a, t) = app()
        session(t, msgs: [.tutor("```tutor-rung\n{\"concept\":\"lock-ttl\",\"confidence\":true}\n```\nWhat?")])
        TutorStub.reset([
            "/tutor": .init(body: "event: session\ndata: {\"session_id\":\"claude-2\"}\n\nevent: token\ndata: {\"t\":\"Right\"}\n\nevent: done\ndata: {\"ok\":true}\n\n", type: "text/event-stream"),
            "/learning-state": .init(body: learningFixture),
        ])
        a.go(.tutor(session: "S1"))
        a.keys.handle("i")
        t.draft = "it expires"
        a.keys.handle("ret")
        #expect(t.askedConfidence)
        #expect(t.sessions[0].msgs.count == 1, "the first ret only asks how sure")
        a.keys.handle("ret")
        #expect(a.keys.mode == .normal)
        #expect(t.draft.isEmpty)
        await settle { !t.streaming && t.sessions[0].msgs.last?.text == "Right" }
        #expect(t.sessions[0].msgs.map(\.role) == ["tutor", "me", "tutor"])
        #expect(t.sessions[0].msgs[1].text == "it expires")
        #expect(t.sessions[0].sessionId == "claude-2")
        let body = TutorStub.sent("/tutor").first??.object ?? [:]
        #expect(body["answer"] == "it expires" && body["resume"] == "claude-1" && body["tab"] == "S1" && body["topic"] == "croon-job-locks")
        #expect(body["turn"]?.string?.isEmpty == false)
        #expect(t.sessions[0].pendingTurn == nil)
    }

    @Test func aTurnStreamsTokensToolsAndTheGraph() async {
        let (a, t) = app()
        let sse = [
            "event: session\ndata: {\"session_id\":\"cs-9\"}\n\n",
            "event: status\ndata: {\"s\":\"thinking\"}\n\n",
            "event: tool\ndata: {\"name\":\"Read\",\"arg\":\"lock.ts\"}\n\n",
            ": ping\n\n",
            "event: token\ndata: {\"t\":\"Hello \"}\n\n",
            "event: token\ndata: {\"t\":\"there?\"}\n\n",
            "event: graph\ndata: {\"topic\":\"croon-job-locks\",\"protocol\":\"p7\",\"errors\":[\"bad map\"]}\n\n",
            "event: done\ndata: {\"ok\":true,\"session_id\":\"cs-9\"}\n\n",
            "event: token\ndata: {\"t\":\"after done is never read\"}\n\n",
        ].joined()
        TutorStub.reset(["/tutor": .init(body: sse, type: "text/event-stream"), "/learning-state": .init(body: learningFixture)])
        await t.start("PR #9273").value
        #expect(a.router.route == .tutor(session: t.sessions[0].id))
        let s = t.sessions[0]
        #expect(s.msgs == [.tutor("Hello there?")])
        #expect(s.sessionId == "cs-9" && s.topic == "croon-job-locks" && s.primed == "p7")
        #expect(s.error == "graph: bad map")
        #expect(s.pendingTurn == nil && !t.streaming && t.status.isEmpty)
        let body = TutorStub.sent("/tutor").first??.object ?? [:]
        #expect(body["target"] == "PR #9273" && body["tab"] == .string(s.id) && body["answer"] == nil)
        await settle { !TutorStub.sent("/learning-state").isEmpty }
        #expect(!TutorStub.sent("/learning-state").isEmpty, "the graph event re-reads the graph")
    }

    @Test func aLostTurnSaysSoAndDropsTheEmptyReply() async {
        let (_, t) = app()
        session(t, msgs: [.tutor("Q?"), .me("A"), .tutor("")])
        t.sessions[0].pendingTurn = "turn-1"
        TutorStub.reset(["/tutor": .init(body: "event: gone\ndata: {}\n\n", type: "text/event-stream")])
        t.reattach()
        await settle { t.sessions[0].pendingTurn == nil }
        #expect(t.sessions[0].msgs.count == 2)
        #expect(t.sessions[0].error?.hasPrefix("that turn was lost") == true)
        #expect(TutorStub.sent("/tutor").first??.object == ["turn": "turn-1", "tab": "S1", "topic": "croon-job-locks"], "re-attaching sends only the turn id")
    }

    @Test func aDroppedStreamRejoinsByTurnIdThenGivesUp() async {
        let (_, t) = app()
        session(t, msgs: [.tutor("Q?")])
        // a stream that ends without done: rejoined twice (maxTries), then the session says so
        TutorStub.reset(["/tutor": .init(body: "event: token\ndata: {\"t\":\"x\"}\n\n", type: "text/event-stream")])
        await t.answer("S1", "an answer")?.value
        let sent = TutorStub.sent("/tutor").map { $0?.object ?? [:] }
        #expect(sent.count == 3)
        #expect(sent[0]["answer"] == "an answer")
        #expect(sent[1]["answer"] == nil && sent[1]["turn"] == sent[0]["turn"])
        #expect(t.sessions[0].msgs.last?.text == "x", "a replayed turn restarts its text")
        #expect(t.sessions[0].error == "lost the turn's stream")
    }

    @Test func anAnswerToAFrozenSimCarriesThePlayedResult() async {
        let (_, t) = app()
        session(t, msgs: [.tutor("```tutor-sim\n{\"scenario\":\"crash-before-bookmark\",\"kernels\":{\"atomicCommit\":false}}\n```\nHow many?")])
        TutorStub.reset(["/tutor": .init(body: "event: done\ndata: {\"ok\":true}\n\n", type: "text/event-stream")])
        await t.answer("S1", "twice")?.value
        let mine = t.sessions[0].msgs[1].text
        #expect(Lesson.spoken(mine) == "twice")
        guard case .simResult(let sc, let off, let outcome, let div) = Lesson.segments(mine)[1] else { Issue.record("no played sim"); return }
        #expect(sc == "crash-before-bookmark" && off == ["atomicCommit"] && outcome == "red" && div.count == 3)
    }

    @Test func theGraphsWritesAreShapedAsTheWebAppSendsThem() throws {
        let (a, t) = app()
        let cmd = { (id: String) in a.registry.command(id)! }
        let close = try #require(try cmd("tutor.question.close").write!("q1", nil))
        #expect(close.path == "/learning-question" && close.body == ["op": "close", "id": "q1"])
        #expect(close.inverse?([:])?.id == "tutor.question.reopen")
        #expect(try cmd("tutor.question.close").write!("nope", nil) == nil)

        let edit = try #require(try cmd("tutor.evidence.edit").write!("ev2", ["outcome": "hit"]))
        #expect(edit.path == "/learning-evidence" && edit.body == ["op": "edit", "id": "ev2", "fields": ["outcome": "hit"]])
        #expect(edit.inverse?([:])?.arg as? [String: String] == ["outcome": "miss"])

        let del = try #require(try cmd("tutor.evidence.delete").write!("ev1", nil))
        #expect(del.body == ["op": "delete", "id": "ev1"])

        t.question = "  why a token?  "
        let ask = try #require(try cmd("tutor.ask").write!("one-runner-per-tick", nil))
        #expect(ask.body == ["op": "add", "text": "why a token?", "concept": "one-runner-per-tick", "topic": "croon-job-locks"])

        session(t, msgs: [.tutor("")])
        t.sessions[0].pendingTurn = "turn-7"
        a.go(.tutor(session: "S1"))
        let stop = try #require(try cmd("tutor.stop").write!("S1", nil))
        #expect(stop.path == "/tutor-stop" && stop.body == ["turn": "turn-7"])
    }

    @Test func theCreditsKeysRouteToTheirEdits() {
        let (a, t) = app()
        t.openDrawer("dead-holder-blocks-forever")
        a.setCursor("e:ev2")
        func routed(_ id: String) -> RouteTo? { a.registry.command(id)?.route?("ev2") }
        #expect(routed("tutor.evidence.outcome")?.arg as? [String: String] == ["outcome": "hit"])
        #expect(routed("tutor.evidence.level")?.arg as? [String: String] == ["level": "explain"])
        #expect(routed("tutor.evidence.credit")?.arg as? [String: String] == ["credit": "handed"])
        #expect(routed("tutor.evidence.confidence")?.arg as? [String: String] == ["confidence": ""])
        #expect(routed("tutor.evidence.cut")?.id == "tutor.evidence.arm")
        a.keys.handle("X")
        #expect(t.armed == "cut ev2")
        #expect(routed("tutor.evidence.cut")?.id == "tutor.evidence.delete")
        a.keys.handle("esc")
        #expect(t.armed == nil && t.drawer != nil, "esc disarms first, then closes")
    }

    @Test func forgettingASessionTakesTwoPresses() {
        let (a, t) = app()
        session(t, msgs: [.tutor("Q?")])
        a.focus(pane: "sessions")
        #expect(a.selected == "s:S1")
        a.keys.handle("X")
        #expect(t.armed == "forget S1" && t.sessions.count == 1)
        a.keys.handle("X")
        #expect(t.sessions.isEmpty)
    }

    @Test func sessionsPersistAcrossLaunches() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("tutor-\(UUID().uuidString)/sessions.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let (_, t) = app()
        t.sessionsFile = file
        session(t, msgs: [.tutor("Q?"), .me("A")])
        t.sessions[0].pendingTurn = "turn-3"
        t.save()
        let back = TutorState.loadSessions(file)
        #expect(back == t.sessions)
    }

    @Test func pickingUpATerminalSessionForksIt() async throws {
        let (a, t) = app()
        TutorStub.reset([
            "/tutor-import": .init(body: #"{"session":"term-1","cwd":"/Users/x/coding/loops-wt-1","target":"","msgs":[{"role":"tutor","text":"Q?"},{"role":"me","text":"A"}]}"#),
        ])
        try await t.pickUp("term-1")
        let s = t.sessions[0]
        #expect(s.importedFrom == "term-1" && s.sessionId == "term-1" && s.forkNext == true && s.cwd == "/Users/x/coding/loops-wt-1")
        #expect(s.target == "picked up from the terminal · loops-wt-1")
        #expect(a.router.route == .tutor(session: s.id))
        t.terminal = [TerminalSession(session: "term-1", cwd: "/x", target: "", mtime: 0, answers: 1, last: ""),
                      TerminalSession(session: "term-2", cwd: "/x", target: "", mtime: 0, answers: 1, last: "")]
        #expect(t.pickable.map(\.session) == ["term-2"])
        TutorStub.reset(["/tutor-import": .init(status: 404, body: #"{"err":"no transcript"}"#)])
        await #expect(throws: (any Error).self) { try await t.pickUp("term-9") }
    }

    @Test func typesAskAtThePinnedCommit() async {
        let (a, t) = app()
        session(t, msgs: [.tutor("x")])
        a.go(.tutor(session: "S1"))
        let detach = TutorArea.attachNav(a)
        defer { detach() }
        TutorStub.reset([
            "/tutor-src": .init(body: #"{"path":"a.ts","ref":"abc","text":"const one = Locks.take(1)\n"}"#),
            "/lsp/hover": .init(body: #"{"ok":true,"contents":"```ts\nconst one: Lock\n```"}"#),
            "/lsp/definition": .init(body: #"{"ok":true,"sha":"abc","locations":[{"path":"b.ts","line":4,"character":2},{"path":"c.ts","line":9}]}"#),
        ])
        t.showPin(Pin(path: "a.ts", ref: "abc", lines: [1, 1]))
        await settle { t.code != nil }
        #expect(a.registry.command("tutor.types")?.available?(nil) == true)
        a.keys.handle("space"); a.keys.handle("k")
        await settle { if case .hover = t.pop { return true }; return false }
        #expect(t.pop == .hover("```ts\nconst one: Lock\n```"))
        let hover = TutorStub.sent("/lsp/hover").first??.object ?? [:]
        #expect(hover["sha"] == "abc" && hover["path"] == "a.ts" && hover["line"] == 1 && hover["character"] == 6 && hover["side"] == "new")
        a.keys.handle("esc")
        #expect(t.pop == nil)
        a.keys.handle("g"); a.keys.handle("d")
        await settle { a.nav.picker != nil }
        #expect(a.nav.picker?.title == "definitions · 2")
        #expect(a.keys.layer == .picker)
        a.keys.handle("ret")
        #expect(t.pin == Pin(path: "b.ts", ref: "abc", lines: [4, 4]), "the picked place opens in the code pane")
        #expect(a.nav.back.first?.path == "a.ts", "and the jumplist remembers where from")
    }
}

/// Opt-in, read-only: decode the live server's tutor reads with the page's own types.
/// `CANOPY_LIVE_PORT=62497 swift test --filter TutorLiveTests` (GETs only — never a POST).
@Suite struct TutorLiveTests {
    static let port = ProcessInfo.processInfo.environment["CANOPY_LIVE_PORT"].flatMap(Int.init)

    @Test(.enabled(if: port != nil)) func theLiveReadsDecode() async throws {
        let t = Transport(port: Self.port!)
        let l = try await t.getJSON("/learning-state", as: LearnState.self)
        #expect(!l.concepts.isEmpty && !l.topics.isEmpty)
        #expect(l.due.allSatisfy { l.concepts[$0] != nil })
        _ = try await t.getJSON("/tutor-terminal", as: [TerminalSession].self)
        let src = try await t.getJSON("/tutor-src?path=package.json&ref=HEAD", as: CodeSrc.self)
        #expect(src.err == nil && src.text?.isEmpty == false)
        print("live: \(l.concepts.count) concepts · \(l.topics.count) topics · \(l.due.count) due · \(l.questions.count) questions · \(l.evidence.count) credits")
    }
}
