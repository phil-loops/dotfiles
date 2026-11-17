import CanopyCore
import Foundation
import Testing
@testable import CanopyUI

struct CaptureFixtureTests {
    let state = #"{"epoch":"fixture","versions":{"git":1},"entities":{"repo":{"r":{"id":"r","name":"r","main":"main","trunk":"abc1234"}}}}"#

    func source(_ manifest: String? = nil, state: String? = nil) throws -> CaptureFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("capture-source-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data((state ?? self.state).utf8).write(to: root.appendingPathComponent("state.json"))
        if let manifest { try Data(manifest.utf8).write(to: root.appendingPathComponent("responses.json")) }
        return try CaptureFixture(directory: root.path)
    }

    func request(_ path: String, method: String = "GET", body: String? = nil) -> URLRequest {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:61998\(path)")!)
        request.httpMethod = method
        request.httpBody = body.map { Data($0.utf8) }
        return request
    }

    @Test func noLiveSourceOrIncompleteFixtureCanPassPreflight() {
        #expect(throws: (any Error).self) { _ = try CaptureFixture(directory: nil) }
        #expect(throws: (any Error).self) { _ = try CaptureFixture(directory: "/missing/capture-source") }
        for state in ["{}", "not json", #"{"epoch":"","versions":{},"entities":{}}"#, #"{"epoch":"fixture","versions":{}}"#] {
            #expect(throws: (any Error).self) { _ = try source(state: state) }
        }
        for manifest in ["{}", #"[{"method":"GET","path":"/state","body":{}}]"#, #"[{"method":"GET","path":"/node?branch=a","body":{}}]"#, #"[{"method":"GET","path":"/x","body":{},"text":"x"}]"#, #"[{"method":"GET","path":"/x","body":{},"status":999}]"#, #"[{"method":"GET","path":"/x","body":{}},{"method":"GET","path":"/x","body":{}}]"#] {
            #expect(throws: (any Error).self) { _ = try source(manifest) }
        }
    }

    @Test func explicitJSONNullIsARecordedBodyRatherThanAMissingField() throws {
        let fixture = try source(#"[{"method":"GET","path":"/nullable","body":null},{"method":"POST","path":"/r/syntax/units","request":null,"body":null}]"#)
        let read = fixture.answer(request("/nullable"))
        #expect(read.status == 200 && read.data == Data("null".utf8))
        #expect(fixture.answer(request("/r/syntax/units", method: "POST", body: "null")).status == 200)
        #expect(fixture.answer(request("/r/syntax/units", method: "POST")).missing)
    }

    @Test func modeledErrorsRemainValidWhileAbsentResponsesAreIncomplete() throws {
        let fixture = try source(#"[{"method":"GET","path":"/r/node","query":{"branch":"a"},"body":{"err":"recorded failure"},"status":503}]"#)
        let failure = fixture.answer(request("/r/node?branch=a"))
        #expect(failure.status == 503 && !failure.missing)
        #expect(fixture.answer(request("/r/node?branch=b")).missing)
    }

    @Test func readinessAndBootstrapComeFromTheFrozenLocalSnapshot() throws {
        let fixture = try source()
        let state = fixture.answer(request("/state?archived=1"))
        #expect(state.status == 200 && state.data == Data(self.state.utf8))
        let bootstrap = fixture.answer(request("/v2"))
        #expect(Bootstrap.parse(html: String(decoding: bootstrap.data, as: UTF8.self))?.repos == ["r"])
        let events = fixture.answer(request("/v2/events?epoch=fixture&git=1"))
        #expect(events.stream && events.type == "text/event-stream")
        #expect(String(decoding: events.data, as: UTF8.self).contains("capture-fixture"))
    }

    @Test func responsesMatchTheWholeQueryAndSemanticRequestBody() throws {
        let fixture = try source(#"[{"method":"GET","path":"/r/node","query":{"branch":"a/b","base":"main"},"body":{"branch":"a/b","files":[]}},{"method":"POST","path":"/r/syntax/units","request":{"path":"a.ts","sha":"abc1234"},"body":{"sha":"abc1234","units":[]}}]"#)
        #expect(fixture.answer(request("/r/node?base=main&branch=a%2Fb")).status == 200)
        #expect(fixture.answer(request("/r/node?base=main&branch=other")).status == 403)
        #expect(fixture.answer(request("/r/node?branch=a%2Fb")).status == 403)
        #expect(fixture.answer(request("/r/node?base=main&branch=a%2Fb&branch=a%2Fb")).status == 403)
        #expect(fixture.answer(request("/r/syntax/units", method: "POST", body: #"{"sha":"abc1234","path":"a.ts"}"#)).status == 200)
        #expect(fixture.answer(request("/r/syntax/units", method: "POST", body: #"{"sha":"different","path":"a.ts"}"#)).status == 403)
        #expect(fixture.answer(request("/r/syntax/units", method: "POST", body: "bad json")).status == 403)
    }

    @MainActor @Test func fixtureHydrationKeepsItsLocalHelloConnectionOpenUntilStopped() async throws {
        let fixture = try source()
        CaptureFixtureProtocol.install(fixture, port: 62001)
        let transport = Transport(base: URL(string: "http://127.0.0.1:62001")!, protocolClasses: [CaptureFixtureProtocol.self])
        let store = Store()
        let stream = EventStream(transport: transport, store: store)
        var hello = false
        stream.onFrame = { if $0.event == "hello" { hello = true } }
        stream.connect()
        defer { stream.stop() }
        for _ in 0..<200 where !hello { try await Task.sleep(nanoseconds: 5_000_000) }
        #expect(hello && store.ready && store.conn == .live)
        #expect(store.epoch == "fixture")
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(store.conn == .live && stream.stats["hello"] == 1)
    }

    @Test func unknownRequestsAndWritesCannotEscapeToAnyNetwork() async throws {
        let fixture = try source(#"[{"method":"POST","path":"/r/push","body":{"ok":true}}]"#)
        CaptureFixtureProtocol.install(fixture, port: 61998)
        let transport = Transport(base: URL(string: "http://127.0.0.1:61998")!, protocolClasses: [CaptureFixtureProtocol.self])
        let reply = await transport.post("/r/push", ["branch": "fixture"])
        #expect(!reply.ok && reply.outcome == .refused && reply.body?["err"] == .string("capture-read-only"))
        #expect(throws: Never.self) { try CaptureFixtureProtocol.requireComplete(port: 61998) }
        for path in ["/r/gates-progress?branch=fixture", "/r/evidence?branch=fixture", "/r/review-flags?branch=fixture", "/r/node?branch=refs%2Fstack%2Ftree-integration", "/future-endpoint"] {
            do { _ = try await transport.getData(path); Issue.record("a missing fixture became a successful read") }
            catch let error as HTTPError { #expect(error.status == 403) }
        }
        #expect(throws: (any Error).self) { try CaptureFixtureProtocol.requireComplete(port: 61998) }
        let outside = URLRequest(url: URL(string: "https://example.com/state")!)
        #expect(CaptureFixtureProtocol.canInit(with: outside))
        #expect(fixture.answer(outside).status == 403)
    }
}
