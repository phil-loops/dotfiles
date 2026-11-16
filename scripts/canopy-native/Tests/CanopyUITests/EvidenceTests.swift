import CanopyCore
import Foundation
import Testing
@testable import CanopyUI

@MainActor @Suite struct EvidenceTests {
    static func card(current: Bool = true, available: Bool = true, running: Bool = false) -> String {
        """
        {"ok":true,"request":{"recipe":"r","expectation":"e"},"id":"abc","current":\(current),"available":\(available),
         "status":{"judged":false},"run":{"running":\(running)},
         "manifest":{"basis":{"beforeCommit":"b","afterCommit":"a"},"recipe":{"title":"T"},"expectation":"e",
           "obligations":[{"id":"light"},{"id":"dark"},{"id":"light-focus"}],
           "before":{"scenes":{}},"after":{"scenes":{}},
           "findings":[{"scene":"light","predicted":"same","changed":false,"departure":false},
                       {"scene":"dark","predicted":"changes","changed":true,"departure":false},
                       {"scene":"light-focus","predicted":"same","changed":true,"departure":true}]}}
        """
    }

    @Test func departuresComeFirstThenTheRecipesOrder() throws {
        let c = try JSONDecoder().decode(EvidenceCard.self, from: Data(Self.card().utf8))
        #expect(c.findings.map(\.scene) == ["light-focus", "light", "dark"])
    }

    @Test func onlyACompleteCurrentIdleManifestCanBeJudged() throws {
        func judgeable(_ s: String) throws -> Bool { try JSONDecoder().decode(EvidenceCard.self, from: Data(s.utf8)).judgeable }
        #expect(try judgeable(Self.card()))
        #expect(try !judgeable(Self.card(current: false)), "a render of an older tree is history, not a thing to judge")
        #expect(try !judgeable(Self.card(available: false)), "images gone from the cache can't be what Phil saw")
        #expect(try !judgeable(Self.card(running: true)), "a render in flight may replace what's on screen")
    }

    @Test func evidenceKeysKeepTheRules() throws {
        let (a, _) = try ShipTests().app()
        let v = KeyboardRule.violations(a) { $0.hasPrefix("evidence.") }
        #expect(v.isEmpty, "\(v)")
        #expect(a.registry.keyProblems.isEmpty, "\(a.registry.keyProblems)")
    }
}
