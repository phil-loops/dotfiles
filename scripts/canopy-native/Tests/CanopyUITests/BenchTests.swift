import CanopyCore
import Foundation
import Testing
@testable import CanopyUI

@MainActor struct BenchTests {
    @Test func benchmarkAnswersVerdictProducingReadsLocally() async throws {
        let transport = Transport(base: URL(string: "http://bench.invalid")!, protocolClasses: [Blackhole.self])
        for path in ["/gates-progress?branch=__probe__", "/loops/gates-progress?branch=__probe__&gate=test"] {
            let request = URLRequest(url: transport.url(path))
            #expect(Blackhole.canInit(with: request))
            let data = try await transport.getData(path)
            let reply = try JSONDecoder().decode(JSONValue.self, from: data)
            #expect(reply["running"] == .bool(false))
            #expect(reply["result"] == nil)
            #expect(reply["err"] == .string("benchmark-local"))
        }
        #expect(!Blackhole.canInit(with: URLRequest(url: transport.url("/state?archived=1"))))
        #expect(!Blackhole.canInit(with: URLRequest(url: transport.url("/loops/node?branch=__probe__"))))
        var write = URLRequest(url: transport.url("/loops/gates"))
        write.httpMethod = "POST"
        #expect(Blackhole.canInit(with: write))
    }
}
