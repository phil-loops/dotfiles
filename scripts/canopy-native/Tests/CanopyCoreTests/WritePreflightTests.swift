import Foundation
import Testing
@testable import CanopyCore

final class HeldWritePreflightStub: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    nonisolated(unsafe) static var held: [Int: HeldWritePreflightStub] = [:]
    nonisolated(unsafe) static var seen: [Int: [String]] = [:]

    static func paths(_ port: Int) -> [String] { lock.withLock { seen[port] ?? [] } }
    static func waiting(_ port: Int) -> Bool { lock.withLock { held[port] != nil } }
    static func release(_ port: Int) { lock.withLock { held.removeValue(forKey: port) }?.respond() }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let port = request.url!.port!, path = request.url!.path
        Self.lock.withLock {
            Self.seen[port, default: []].append(path)
            if path == "/held" { Self.held[port] = self }
        }
        if path != "/held" { respond() }
    }
    override func stopLoading() {}
    private func respond() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"ok":true}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

@MainActor @Suite(.serialized) struct WritePreflightTests {
    static var nextPort = 58000

    func setup() throws -> (Runner, Store, Int) {
        Self.nextPort += 1
        let port = Self.nextPort
        let transport = Transport(base: URL(string: "http://stub.test:\(port)")!, protocolClasses: [HeldWritePreflightStub.self])
        let store = Store()
        store.hydrate(try Snapshot.decode(fixture("state.json")))
        return (Runner(registry: CommandRegistry(), store: store, transport: transport,
                       telemetry: Telemetry(transport: transport, enabled: false)), store, port)
    }

    func wait(_ predicate: () -> Bool) async {
        for _ in 0..<300 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("timed out waiting for a preflight write")
    }

    @Test func aQueuedWriteRevalidatesAfterItsPredecessorAndRollsBackWithoutPosting() async throws {
        let (runner, store, port) = try setup()
        let id = "loops:add-hankles-limited-label"
        var allowed = true, validations = 0, rollbacks = 0, inverses = 0
        var answers: [Bool] = []
        runner.registry.register(Command(id: "hold", title: "Hold", scope: .global, write: { _, _ in
            Write(path: "/held", body: [:], settled: { true }, failed: "hold failed")
        }))
        runner.registry.register(Command(id: "checked", title: "Checked", scope: .global, write: { _, _ in
            var write = Write(ops: [Op(type: .branch, id: id, fields: ["pending": "staged"])], path: "/checked", body: [:],
                settled: { true }, failed: "write failed", inverse: { _ in inverses += 1; return nil },
                rollback: { rollbacks += 1 }, answered: { ok, _ in answers.append(ok) })
            write.refuseBeforeSend = { validations += 1; return allowed ? nil : "source changed" }
            return write
        }))
        runner.dispatch("hold", via: .key, target: id)
        await wait { HeldWritePreflightStub.waiting(port) }
        runner.dispatch("checked", via: .key, target: id)
        #expect(store.view(Branch.self, id)?.pending == "staged" && validations == 0)
        allowed = false
        HeldWritePreflightStub.release(port)
        await wait { runner.runOf("checked", id)?.state == .failed }
        #expect(HeldWritePreflightStub.paths(port) == ["/held"])
        #expect(validations == 1 && rollbacks == 1 && inverses == 0 && answers == [false])
        #expect(store.view(Branch.self, id)?.pending == nil)
        #expect(runner.note == "write failed — source changed")
    }

    @Test(arguments: [false, true]) func preflightAlsoRunsBeforeAnImmediateOrIndependentWrite(_ alone: Bool) async throws {
        let (runner, _, port) = try setup()
        var validations = 0
        runner.registry.register(Command(id: "checked", title: "Checked", scope: .global, write: { _, _ in
            var write = Write(path: "/checked", body: [:], settled: { true }, failed: "write failed", alone: alone)
            write.refuseBeforeSend = { validations += 1; return "source changed" }
            return write
        }))
        runner.dispatch("checked", via: .key, target: "target")
        await wait { runner.runOf("checked", "target")?.state == .failed }
        #expect(validations == 1 && HeldWritePreflightStub.paths(port).isEmpty)
    }

    @Test func aValidQueuedWriteSendsOnceAndAnUnvalidatedWriteKeepsItsExistingBehavior() async throws {
        let (runner, _, port) = try setup()
        var validations = 0
        runner.registry.register(Command(id: "hold", title: "Hold", scope: .global, write: { _, _ in
            Write(path: "/held", body: [:], settled: { true }, failed: "hold failed")
        }))
        runner.registry.register(Command(id: "checked", title: "Checked", scope: .global, write: { _, _ in
            var write = Write(path: "/checked", body: [:], settled: { true }, failed: "write failed")
            write.refuseBeforeSend = { validations += 1; return nil }
            return write
        }))
        runner.dispatch("hold", via: .key, target: "target")
        runner.dispatch("checked", via: .key, target: "target")
        await wait { HeldWritePreflightStub.waiting(port) }
        #expect(validations == 0 && HeldWritePreflightStub.paths(port) == ["/held"])
        HeldWritePreflightStub.release(port)
        await wait { runner.runOf("checked", "target")?.state == .done }
        #expect(validations == 1 && HeldWritePreflightStub.paths(port) == ["/held", "/checked"])
    }
}
