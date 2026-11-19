import CanopyTestSupport
import Foundation
import Testing
@testable import CanopyCore

final class StateLoadStub: URLProtocol, @unchecked Sendable {
    struct Reply { var data: Data; var delay: Double }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var replies: [String: Reply] = [:]

    static func transport(_ data: Data, delay: Double = 0) -> Transport {
        let host = "\(UUID().uuidString.lowercased()).invalid"
        lock.withLock { replies[host] = Reply(data: data, delay: delay) }
        return Transport(base: URL(string: "http://\(host)")!, protocolClasses: [Self.self])
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let reply = Self.lock.withLock { Self.replies[request.url!.host!]! }
        let state = request.url?.path == "/state"
        DispatchQueue.global().asyncAfter(deadline: .now() + reply.delay) { [self] in
            let response = HTTPURLResponse(url: request.url!, statusCode: state ? 200 : 404, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: state ? reply.data : Data())
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

@MainActor struct StateLoadTests {
    @Test func stateTimingSeparatesHeldFetchFromDecodeAndHydration() async throws {
        let transport = StateLoadStub.transport(try fixture("state.json"), delay: 0.15)
        let store = Store()
        let stream = EventStream(transport: transport, store: store)
        var order: [String] = [], timings: [String: Double] = [:]
        stream.count = { name, ms in
            guard let ms else { return }
            order.append(name)
            timings[name] = ms
        }
        stream.connect()
        defer { stream.stop() }
        await until("timings[state] == nil") { !(timings["state"] == nil) }
        #expect(store.ready)
        #expect(!store.raw.isEmpty)
        #expect(order == ["state-fetch", "state-decode", "state-hydrate", "state"])
        #expect(try #require(timings["state-fetch"]) >= 100)
        let phases = try ["state-fetch", "state-decode", "state-hydrate"].map { try #require(timings[$0]) }
        #expect(phases.allSatisfy { $0 >= 0 })
        #expect(abs(phases.reduce(0, +) - (try #require(timings["state"]))) < 0.01)
    }

    @Test func invalidStateDoesNotReportACompletedLoad() async throws {
        let store = Store()
        let stream = EventStream(transport: StateLoadStub.transport(Data("{}".utf8)), store: store)
        stream.connect()
        defer { stream.stop() }
        await until("stream.stats[reconnect] == nil") { !(stream.stats["reconnect"] == nil) }
        #expect(stream.stats["reconnect"] == 1)
        #expect(!store.ready)
        #expect(stream.stats["state"] == nil)
        #expect(stream.stats["state-decode"] == nil)
        #expect(stream.stats["state-hydrate"] == nil)
    }
}
