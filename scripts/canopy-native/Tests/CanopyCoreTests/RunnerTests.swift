import Foundation
import Testing
@testable import CanopyCore

/// Answers every request from a per-path table, recording what was sent.
final class Stub: URLProtocol, @unchecked Sendable {
    struct Answer { var status: Int; var body: String; var headers: [String: String] = [:]; var lost = false }
    nonisolated(unsafe) static var answers: [String: Answer] = [:]
    nonisolated(unsafe) static var seen: [URLRequest] = []
    static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        let a = Stub.lock.withLock { Stub.seen.append(request); return Stub.answers[path] } ?? Answer(status: 404, body: "{}")
        if a.lost { return client!.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost)) }
        let resp = HTTPURLResponse(url: request.url!, statusCode: a.status, httpVersion: "HTTP/1.1", headerFields: a.headers)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(a.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
final class Ctx: CommandContext {
    var targets: [Scope: String] = [:]
    var scopes: [Scope] = [.global]
    func target(for scope: Scope) -> String? { targets[scope] }
    func liveScopes() -> [Scope] { scopes }
    func closeMenu() {}
    var jumps = 0
    func willJump(_ id: String) { jumps += 1 }
    var at = Place(route: .forests, pane: "main", cursorKey: "a")
    func placeNow() -> Place? { at }
    func returnTo(_ p: Place) { at = p }
}

@MainActor @Suite(.serialized) struct RunnerTests {
    let transport = Transport(base: URL(string: "http://stub.test")!, protocolClasses: [Stub.self])

    func setup() throws -> (Runner, Store, Ctx) {
        let store = Store()
        store.hydrate(try Snapshot.decode(fixture("state.json")))
        let reg = CommandRegistry()
        let runner = Runner(registry: reg, store: store, transport: transport, telemetry: Telemetry(transport: transport, enabled: false))
        let ctx = Ctx()
        runner.context = ctx
        return (runner, store, ctx)
    }

    @Test func aSessionRefusalPrecedesRoutingAndEveryKindOfEffect() throws {
        let (runner, _, ctx) = try setup()
        var effects = 0
        var counted = 0
        runner.onRun = { _ in counted += 1 }
        runner.registry.register(Command(id: "local", title: "Local", scope: .global, recordsJump: true, local: { _, _ in effects += 1 }))
        runner.registry.register(Command(id: "route", title: "Route", scope: .global, route: { _ in effects += 1; return RouteTo("local") }))
        runner.registry.register(Command(id: "task", title: "Task", scope: .global, task: { _, _ in effects += 1; return nil }))
        runner.registry.register(Command(id: "write", title: "Write", scope: .row, write: { _, _ in effects += 1; return nil }))
        ctx.targets[.row] = "row"
        runner.refusal = { _ in "read-only session" }
        for id in ["local", "route", "task", "write"] {
            try runner.arm("pending")
            runner.dispatch(id, via: .key)
            #expect(effects == 0 && counted == 0 && ctx.jumps == 0)
            #expect(runner.note == "read-only session" && runner.fired?.ok == false)
            #expect(runner.armed == nil && runner.runOf(id, nil) == nil)
        }
        runner.refusal = nil
        runner.dispatch("route", via: .key)
        #expect(effects == 2 && counted == 1)
    }

    @Test func aConfirmLastsOneCommandAndRetNeverArmsOrSends() throws {
        let (runner, _, ctx) = try setup()
        let r = runner.registry
        ctx.targets[.row] = "r1"
        var built = 0
        r.register(Command(id: "t.arm", title: "A", scope: .row, local: { t, _ in try runner.arm("x \(t ?? "")") }))
        r.register(Command(id: "t.move", title: "M", scope: .global, local: { _, _ in }))
        r.register(Command(id: "t.send", title: "S", scope: .row, write: { _, _ in
            built += 1
            return Write(path: "/ok", body: [:], settled: { true }, failed: "no")
        }))
        r.register(Command(id: "t.open.arm", title: "OA", scope: .row, verb: .main, route: { t in RouteTo("t.arm", target: t) }))
        r.register(Command(id: "t.open.send", title: "OS", scope: .row, verb: .main, route: { t in RouteTo("t.send", target: t) }))

        runner.dispatch("t.arm", via: .key)
        #expect(runner.armed == "x r1")
        runner.dispatch("t.move", via: .key)
        #expect(runner.armed == nil, "any other command drops the confirm")

        runner.dispatch("t.arm", via: .key)
        runner.dispatch("t.arm", via: .key)
        #expect(runner.armed == "x r1", "arming again keeps it")

        runner.dispatch("t.open.arm", via: .key)
        #expect(runner.armed == nil, "ret never arms")
        runner.dispatch("t.open.send", via: .key)
        #expect(built == 0, "ret never sends")
    }

    @Test func aTaskIsOkOnlyOnceItHasFinished() async throws {
        let (runner, _, _) = try setup()
        var go: CheckedContinuation<Void, Never>?
        runner.registry.register(Command(id: "t.slow", title: "S", scope: .global, task: { _, _ in
            await withCheckedContinuation { go = $0 }
            return "done"
        }))
        runner.registry.register(Command(id: "t.no", title: "N", scope: .global, task: { _, _ in throw Refusal("not here") }))
        runner.dispatch("t.slow", via: .key)
        for _ in 0..<100 where go == nil { try await Task.sleep(nanoseconds: 1_000_000) }
        #expect(runner.runOf("t.slow", nil)?.state == .sending && runner.fired == nil, "running: no ok yet")
        go?.resume()
        for _ in 0..<100 where runner.runOf("t.slow", nil)?.state == .sending { try await Task.sleep(nanoseconds: 1_000_000) }
        #expect(runner.runOf("t.slow", nil)?.state == .done && runner.fired?.ok == true && runner.note == "done", "ok once it finished")
        runner.dispatch("t.no", via: .key)
        for _ in 0..<100 where runner.runOf("t.no", nil)?.state != .failed { try await Task.sleep(nanoseconds: 1_000_000) }
        #expect(runner.fired?.ok == false && runner.note == "not here", "a throw is the refusal")
    }

    @Test func aKeyPressedBeforeItsPageCanActIsHeldAndRunsOnRelease() throws {
        let (runner, _, _) = try setup()
        var ready = false, ran = 0
        runner.registry.register(Command(id: "t.next", title: "N", scope: .global, local: { _, _ in
            guard ready else { throw Hold("reading — runs when it's in") }
            ran += 1
        }))
        runner.registry.register(Command(id: "t.other", title: "O", scope: .global, local: { _, _ in }))
        runner.dispatch("t.next", via: .key)
        #expect(runner.held?.id == "t.next" && ran == 0 && runner.note == "reading — runs when it's in")
        ready = true
        runner.releaseHeld()
        #expect(ran == 1 && runner.held == nil, "the held key runs once the page is ready")
        ready = false
        runner.dispatch("t.next", via: .key)
        runner.dispatch("t.other", via: .key)
        #expect(runner.held == nil, "any other key drops the hold")
        runner.registry.register(Command(id: "t.nowhere", title: "W", scope: .global, route: { _ in nil }))
        runner.registry.register(Command(id: "t.off", title: "F", scope: .global, available: { _ in false }, local: { _, _ in }))
        for other in ["t.nowhere", "t.off"] {
            runner.dispatch("t.next", via: .key)
            runner.dispatch(other, via: .key)
            #expect(runner.held == nil, "a key that does nothing still drops the hold: \(other)")
        }
        runner.dispatch("t.next", via: .key)
        runner.disarm()
        #expect(runner.held == nil, "a page change drops it too")
        runner.releaseHeld()
        #expect(ran == 1)
    }

    @Test func postRefusalSemantics() async {
        Stub.answers = [
            "/ok": .init(status: 200, body: #"{"ok":true,"n":1}"#),
            "/no": .init(status: 200, body: #"{"ok":false,"err":"not fast-forward"}"#, headers: ["X-Stack-Refused": "not-fast-forward"]),
            "/bad": .init(status: 400, body: "{}"),
            "/boom": .init(status: 500, body: "oops"),
        ]
        let ok = await transport.post("/ok", ["branch": "__probe__"] as JSONValue, via: .key)
        #expect(ok.ok && ok.outcome == .ok && ok.body?["n"]?.int == 1)
        let no = await transport.post("/no", JSONValue.object([:]))
        #expect(!no.ok && no.outcome == .refused && no.err == "not-fast-forward")
        let bad = await transport.post("/bad", JSONValue.object([:]))
        #expect(bad.outcome == .refused && bad.err == "http-400")
        let boom = await transport.post("/boom", JSONValue.object([:]))
        #expect(boom.outcome == .failed && boom.err == "http-500")
        let sent = Stub.lock.withLock { Stub.seen.first { $0.url?.path == "/ok" } }
        #expect(sent?.value(forHTTPHeaderField: "X-Stack-Actor") == "browser")
        #expect(sent?.value(forHTTPHeaderField: "X-Stack-Via") == "key")
        #expect(sent?.value(forHTTPHeaderField: "X-Request-Id")?.hasPrefix(transport.pageLoad + "-") == true)
    }

    @Test func atRepoNeverDropsANamedRepo() {
        transport.repos = ["loops"]
        #expect(transport.atRepo("loops", "/node?branch=x") == "/loops/node?branch=x")
        #expect(transport.atRepo("other", "/node") == "/other/node")
        #expect(transport.atRepo("", "/node") == "/node")
        transport.repos = []
        #expect(transport.atRepo("loops", "/review-draft") == "/loops/review-draft")
    }

    @Test func localCommandAndRefusal() throws {
        let (runner, _, ctx) = try setup()
        var ran: [String?] = []
        runner.registry.register(Command(id: "t.local", title: "T", scope: .row, local: { t, _ in ran.append(t) }))
        runner.registry.register(Command(id: "t.refuse", title: "R", scope: .global, local: { _, _ in throw Refusal("nothing to undo") }))
        runner.registry.register(Command(id: "t.never", title: "N", scope: .global, available: { _ in false }, local: { _, _ in ran.append("never") }))
        ctx.targets[.row] = "p:x"
        runner.dispatch("t.local", via: .click)
        runner.dispatch("t.local", via: .click, target: "explicit")
        runner.dispatch("t.never", via: .key)
        #expect(ran == ["p:x", "explicit"])
        runner.dispatch("t.refuse", via: .click)
        #expect(runner.note == "nothing to undo")
        // a key's refusal keeps its reason; "nothing here" is only for a key with nothing to act on
        runner.dispatch("t.refuse", via: .key)
        #expect(runner.note == "nothing to undo")
        runner.dispatch("t.never", via: .key)
        #expect(runner.note == " · nothing here")
    }

    @Test func routeSendsTheKeyOn() throws {
        let (runner, _, _) = try setup()
        var got: String?
        runner.registry.register(Command(id: "t.real", title: "Real", scope: .global, local: { t, _ in got = t }))
        runner.registry.register(Command(id: "t.ret", title: "Ret", scope: .global, route: { _ in RouteTo("t.real", target: "b:y") }))
        runner.dispatch("t.ret", via: .key)
        #expect(got == "b:y")
    }

    @Test func refusedWriteRollsBackTheOverlay() async throws {
        let (runner, store, _) = try setup()
        Stub.answers["/describe"] = .init(status: 200, body: #"{"ok":false,"err":"branch is gone"}"#, headers: ["X-Stack-Refused": "gone"])
        let id = "loops:add-hankles-limited-label"
        var rolledBack = false
        runner.registry.register(Command(id: "t.write", title: "W", scope: .branch, budget: .configWrite, write: { target, _ in
            Write(ops: [Op(type: .branch, id: target, fields: ["description": "new words"])], path: "/describe",
                  body: ["branch": "__probe__"], settled: { false }, failed: "couldn't describe it", rollback: { rolledBack = true })
        }))
        runner.dispatch("t.write", via: .key, target: id)
        #expect(store.view(Branch.self, id)?.description == "new words")
        #expect(runner.runOf("t.write", id)?.state == .sending)
        for _ in 0..<50 where runner.runOf("t.write", id)?.state == .sending { try await Task.sleep(nanoseconds: 20_000_000) }
        #expect(runner.runOf("t.write", id)?.state == .failed)
        #expect(store.ops.isEmpty)
        #expect(rolledBack)
        #expect(runner.note == "couldn't describe it — branch is gone")
    }

    @Test func acceptedWriteKeepsOverlayUntilSettledAndRecordsUndo() async throws {
        let (runner, store, _) = try setup()
        Stub.answers["/describe"] = .init(status: 200, body: #"{"ok":true}"#)
        let id = "loops:add-hankles-limited-label"
        var settled = false
        runner.registry.register(Command(id: "t.write2", title: "W", scope: .branch, write: { target, _ in
            Write(ops: [Op(type: .branch, id: target, fields: ["description": "new"])], path: "/describe", body: [:],
                  settled: { settled }, said: "described", failed: "no", inverse: { _ in Inverse(id: "t.undo", target: target) })
        }))
        var undone = false
        runner.registry.register(Command(id: "t.undo", title: "U", scope: .branch, local: { _, _ in undone = true }))
        runner.dispatch("t.write2", via: .key, target: id)
        for _ in 0..<50 where runner.runOf("t.write2", id)?.state == .sending { try await Task.sleep(nanoseconds: 20_000_000) }
        #expect(runner.runOf("t.write2", id)?.state == .landing)
        #expect(store.view(Branch.self, id)?.description == "new")
        settled = true
        store.nudge()
        #expect(store.ops.isEmpty)
        #expect(runner.runOf("t.write2", id)?.state == .done)
        #expect(runner.undoLast())
        #expect(undone)
        #expect(!runner.undoLast())
    }

    @Test func undoAndARefusalPutTheCursorBackWhereTheWriteMovedItFrom() async throws {
        let (runner, _, ctx) = try setup()
        Stub.answers["/moves-ok"] = .init(status: 200, body: #"{"ok":true}"#)
        Stub.answers["/moves-no"] = .init(status: 200, body: #"{"ok":false,"err":"no"}"#)
        let id = "loops:add-hankles-limited-label"
        for path in ["/moves-ok", "/moves-no"] {
            runner.registry.register(Command(id: "t\(path)", title: "W", scope: .branch, write: { target, _ in
                ctx.at.cursorKey = "next"   // , m moves on as part of marking
                return Write(path: path, body: [:], settled: { true }, failed: "no", inverse: { _ in Inverse(id: "t.back", target: target) })
            }))
        }
        runner.registry.register(Command(id: "t.back", title: "U", scope: .branch, local: { _, _ in }))

        runner.dispatch("t/moves-ok", via: .key, target: id)
        for _ in 0..<50 where runner.runOf("t/moves-ok", id)?.state == .sending { try await Task.sleep(nanoseconds: 20_000_000) }
        #expect(ctx.at.cursorKey == "next")
        #expect(runner.undoLast())
        #expect(ctx.at.cursorKey == "a", "u puts the mark back and the cursor where it was made")

        runner.dispatch("t/moves-no", via: .key, target: id)
        for _ in 0..<50 where runner.runOf("t/moves-no", id)?.state == .sending { try await Task.sleep(nanoseconds: 20_000_000) }
        #expect(ctx.at.cursorKey == "a", "a refused write takes its move back")

        runner.dispatch("t/moves-no", via: .key, target: id)
        ctx.at.cursorKey = "elsewhere"   // moved on before the refusal came back
        for _ in 0..<50 where runner.runOf("t/moves-no", id)?.state == .sending { try await Task.sleep(nanoseconds: 20_000_000) }
        #expect(ctx.at.cursorKey == "elsewhere", "a late refusal never yanks the cursor away from where it went")
    }

    /// The focus-lane burst (2026-11-05): press 4 put a forest at rank 1, press 5 moved it down, press 6
    /// back up. A read from before press 5 already shows rank 1 — it must not pass for press 6.
    @Test func aWriteLandsOnlyOnAReadThatHasSeenIt() async throws {
        let (runner, store, _) = try setup()
        let id = "loops:agents-md"
        var obj = store.raw["project"]![id]!.object!
        func patch(_ v: Int, asOf: Int, rank: Int) throws -> Patch {
            obj["rank"] = .number(Double(rank))
            return try Patch.make(domain: Domain.git, version: v, asOf: asOf, upserts: ["project": [id: .object(obj)]])
        }
        let v = store.versions[Domain.git] ?? 0
        #expect(store.applyPatch(try patch(v + 1, asOf: 4, rank: 1)) == .ok)
        Stub.answers["/focus"] = .init(status: 200, body: #"{"ok":true,"wrote":6}"#)
        runner.registry.register(Command(id: "t.rank", title: "R", scope: .project, write: { target, _ in
            Write(ops: [Op(type: .project, id: target, fields: ["rank": 1])], path: "/focus", body: [:],
                  settled: { store.table(Project.self)[target]?.rank == 1 }, failed: "no")
        }))
        runner.dispatch("t.rank", via: .key, target: id)
        for _ in 0..<50 where runner.runOf("t.rank", id)?.state == .sending { try await Task.sleep(nanoseconds: 20_000_000) }
        #expect(runner.runOf("t.rank", id)?.state == .landing)
        #expect(!store.ops.isEmpty)
        #expect(store.applyPatch(try patch(v + 2, asOf: 5, rank: 2)) == .ok)
        #expect(store.view(Project.self, id)?.rank == 1)
        #expect(!store.ops.isEmpty)
        #expect(store.applyPatch(try patch(v + 3, asOf: 6, rank: 1)) == .ok)
        #expect(store.ops.isEmpty)
        #expect(runner.runOf("t.rank", id)?.state == .done)
    }

    @Test func aWriteFromAServerThatDoesntNumberItSettlesOnItsCheck() async throws {
        let (runner, store, _) = try setup()
        Stub.answers["/describe"] = .init(status: 200, body: #"{"ok":true}"#)
        let id = "loops:add-hankles-limited-label"
        runner.registry.register(Command(id: "t.old", title: "W", scope: .branch, write: { target, _ in
            Write(ops: [Op(type: .branch, id: target, fields: ["description": "new"])], path: "/describe", body: [:],
                  settled: { true }, failed: "no")
        }))
        runner.dispatch("t.old", via: .key, target: id)
        for _ in 0..<50 where runner.runOf("t.old", id)?.state == .sending { try await Task.sleep(nanoseconds: 20_000_000) }
        #expect(runner.runOf("t.old", id)?.state == .done)
        #expect(store.ops.isEmpty)
    }

    /// 2026-11-18: a push landed but its answer was lost, and the page said it didn't push. A lost
    /// answer is an unknown: the write's own check decides, once a read comes back.
    @Test func aLostAnswerIsSettledByTheWritesOwnCheck() async throws {
        let (runner, store, _) = try setup()
        Stub.answers["/push"] = .init(status: 0, body: "", lost: true)
        let id = "loops:add-hankles-limited-label"
        var onServer = false
        var resyncs = 0
        runner.resync = { resyncs += 1 }
        runner.registry.register(Command(id: "t.push", title: "P", scope: .branch, write: { _, _ in
            Write(path: "/push", body: [:], settled: { onServer }, said: "pushed", failed: "didn't push")
        }))
        runner.dispatch("t.push", via: .key, target: id)
        for _ in 0..<50 where runner.runOf("t.push", id)?.state == .sending { try await Task.sleep(nanoseconds: 20_000_000) }
        #expect(runner.runOf("t.push", id)?.state == .landing)
        #expect(runner.note == "no answer · checking whether it landed")
        #expect(resyncs == 1)
        onServer = true
        store.nudge()
        #expect(runner.runOf("t.push", id)?.state == .done)
        #expect(runner.note == "pushed")
    }

    @Test func aLostAnswerTheServerDoesntShowIsAFailure() async throws {
        let (runner, store, _) = try setup()
        Stub.answers["/push"] = .init(status: 0, body: "", lost: true)
        let id = "loops:add-hankles-limited-label"
        runner.resync = { store.hydrate(try! Snapshot.decode(fixture("state.json"))) }
        runner.registry.register(Command(id: "t.push2", title: "P", scope: .branch, write: { _, _ in
            Write(path: "/push", body: [:], settled: { false }, said: "pushed", failed: "didn't push")
        }))
        runner.dispatch("t.push2", via: .key, target: id)
        for _ in 0..<50 where runner.runOf("t.push2", id)?.state != .failed { try await Task.sleep(nanoseconds: 20_000_000) }
        #expect(runner.runOf("t.push2", id)?.state == .failed)
        #expect(runner.note == "didn't push — no answer, and the server doesn't show it")
    }

    @Test func aLostAnswerWithACheckThatCantTellSaysSo() async throws {
        let (runner, _, _) = try setup()
        Stub.answers["/next"] = .init(status: 0, body: "", lost: true)
        let id = "loops:add-hankles-limited-label"
        runner.registry.register(Command(id: "t.next", title: "N", scope: .branch, write: { _, _ in
            Write(path: "/next", body: [:], settled: { true }, failed: "the gates didn't queue")
        }))
        runner.dispatch("t.next", via: .key, target: id)
        for _ in 0..<50 where runner.runOf("t.next", id)?.state != .failed { try await Task.sleep(nanoseconds: 20_000_000) }
        #expect(runner.note == "the gates didn't queue — no answer, so it may have landed — the page shows what the server has")
    }

    @Test func keyEngineDrivesTheRunner() throws {
        let (runner, _, ctx) = try setup()
        var hits: [String] = []
        runner.registry.register(Command(id: "nav.x", title: "Go to X — somewhere", scope: .global, verb: .goForests, local: { _, _ in hits.append("gx") }))
        runner.registry.register(Command(id: "row.y", title: "Y", scope: .row, verb: .typeDefinition, local: { _, _ in hits.append("gy") }))
        runner.registry.applyUserKeys([:])
        let keys = KeyEngine(registry: runner.registry, runner: runner)
        #expect(keys.handle("g"))
        #expect(keys.pendingKeys == "g")
        #expect(keys.whichKeyRows().map(\.key) == ["F"])
        #expect(keys.whichKeyRows().map(\.verb) == ["go-forests"])
        #expect(keys.handle("F"))
        #expect(keys.pendingKeys == "")
        ctx.scopes = [.row, .global]
        keys.handle("g"); keys.handle("y")
        #expect(hits == ["gx", "gy"])
        #expect(!keys.handle("q"))
        // keys.toml names the verb; every command doing it follows
        runner.registry.applyUserKeys(["go-forests": ["Q"]])
        #expect(keys.handle("Q"))
        #expect(hits.last == "gx")
        #expect(runner.registry.customized == [.goForests])
        // a v2 command-id line is read past with a warning, never a problem
        runner.registry.applyUserKeys(["nav.x": ["Z"]])
        #expect(runner.registry.keyProblems.isEmpty)
        #expect(runner.registry.keyWarnings.first?.contains("go-forests") == true)
        #expect(runner.registry.command("nav.x")?.keys == ["g F"])
    }
}
