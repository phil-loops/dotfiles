import Foundation
import Testing
@testable import CanopyCore

/// Answers every request from a per-path table, recording what was sent.
final class Stub: URLProtocol, @unchecked Sendable {
    struct Answer { var status: Int; var body: String; var headers: [String: String] = [:] }
    nonisolated(unsafe) static var answers: [String: Answer] = [:]
    nonisolated(unsafe) static var seen: [URLRequest] = []
    static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        let a = Stub.lock.withLock { Stub.seen.append(request); return Stub.answers[path] } ?? Answer(status: 404, body: "{}")
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

    @Test func atRepoPinsOnlyKnownRepos() {
        transport.repos = ["loops"]
        #expect(transport.atRepo("loops", "/node?branch=x") == "/loops/node?branch=x")
        #expect(transport.atRepo("other", "/node") == "/node")
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
        // a key's refusal echoes over it, as runner.ts does
        runner.dispatch("t.refuse", via: .key)
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

    @Test func keyEngineDrivesTheRunner() throws {
        let (runner, _, ctx) = try setup()
        var hits: [String] = []
        runner.registry.register(Command(id: "nav.x", title: "Go to X — somewhere", scope: .global, keys: ["g x"], local: { _, _ in hits.append("gx") }))
        runner.registry.register(Command(id: "row.y", title: "Y", scope: .row, keys: ["g y"], local: { _, _ in hits.append("gy") }))
        runner.registry.applyUserKeys([:])
        let keys = KeyEngine(registry: runner.registry, runner: runner)
        #expect(keys.handle("g"))
        #expect(keys.pendingKeys == "g")
        #expect(keys.whichKeyRows().map(\.key) == ["x"])
        #expect(keys.handle("x"))
        #expect(keys.pendingKeys == "")
        ctx.scopes = [.row, .global]
        keys.handle("g"); keys.handle("y")
        #expect(hits == ["gx", "gy"])
        #expect(!keys.handle("q"))
        runner.registry.applyUserKeys(["nav.x": ["Q"]])
        #expect(keys.handle("Q"))
        #expect(hits.last == "gx")
        #expect(runner.registry.customized == ["nav.x"])
        runner.registry.applyUserKeys([:])
        #expect(runner.registry.command("nav.x")?.keys == ["g x"])
    }
}
