import AppKit
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

    @Test func aVerdictWaitsForEveryImageToBeOnScreen() throws {
        let s = Self.card().replacingOccurrences(of: "\"before\":{\"scenes\":{}},\"after\":{\"scenes\":{}}",
                                                 with: "\"before\":{\"scenes\":{\"light\":\"s1\"}},\"after\":{\"scenes\":{\"light\":\"s2\"}}")
        let c = try JSONDecoder().decode(EvidenceCard.self, from: Data(s.utf8))
        #expect(c.judgeable(showing: { ["s1", "s2"].contains($0) }))
        #expect(!c.judgeable(showing: { $0 == "s1" }), "a tile still blank (slow or failed download) isn't something Phil saw")
    }

    @Test func samePixelsInANewPlaceSayTheyMoved() throws {
        let f = try JSONDecoder().decode(EvidenceCard.Finding.self, from: Data(
            "{\"scene\":\"s\",\"predicted\":\"same\",\"changed\":false,\"moved\":true,\"departure\":true}".utf8))
        #expect(f.observedWords == "same pixels, moved on the page")
    }

    @Test func aFieldPredictionSaysWhereTheChangeLanded() throws {
        func f(_ changed: Bool, _ contained: Bool?) throws -> EvidenceCard.Finding {
            let c = contained.map { ",\"contained\":\($0)" } ?? ""
            return try JSONDecoder().decode(EvidenceCard.Finding.self, from: Data(
                "{\"scene\":\"s\",\"predicted\":\"field\",\"changed\":\(changed),\"departure\":false\(c)}".utf8))
        }
        #expect(try f(true, true).predictedWords == "only the field changes")
        #expect(try f(true, true).observedWords == "changed, only the field")
        #expect(try f(true, false).observedWords == "changed beyond the field")
        #expect(try f(false, nil).observedWords == "unchanged")
    }

    static let app = """
    {"request":{"recipe":"r","expectation":"e"},"id":"m","current":true,"available":true,"status":{"judged":false},
     "manifest":{"basis":{"beforeCommit":"b","afterCommit":"a"},"recipe":{"title":"T"},"expectation":"e","gaps":["svix"],
       "obligations":[
         {"id":"rate-light","view":"rate","viewTitle":"Rate limit","variant":"light","variantTitle":"light"},
         {"id":"rate-dark","view":"rate","viewTitle":"Rate limit","variant":"dark","variantTitle":"dark"},
         {"id":"notes-light","view":"notes","viewTitle":"Notes","variant":"light","variantTitle":"light"},
         {"id":"notes-dark","view":"notes","viewTitle":"Notes","variant":"dark","variantTitle":"dark"}],
       "before":{"scenes":{},"fields":{"rate-dark":[48,48,372,76],"notes-dark":[48,48,996,324]}},
       "after":{"scenes":{},"fields":{"rate-dark":[48,48,412,76],"notes-dark":[48,48,996,324]}},
       "findings":[
         {"scene":"rate-light","predicted":"field","changed":true,"departure":false,"contained":true},
         {"scene":"rate-dark","predicted":"field","changed":true,"departure":true,"contained":false},
         {"scene":"notes-light","predicted":"field","changed":true,"departure":false,"contained":true},
         {"scene":"notes-dark","predicted":"field","changed":false,"departure":true}]}}
    """

    @Test func scenesGroupIntoFieldsAndVariants() throws {
        let c = try JSONDecoder().decode(EvidenceCard.self, from: Data(Self.app.utf8))
        #expect(c.fields.map(\.id) == ["rate", "notes"])
        #expect(c.fields[0].title == "Rate limit")
        #expect(c.fields[0].scenes == ["light": "rate-light", "dark": "rate-dark"])
        #expect(c.variants.map(\.id) == ["light", "dark"])
    }

    @Test func aComponentRecipeKeepsEachSceneAsItsOwnField() throws {
        let c = try JSONDecoder().decode(EvidenceCard.self, from: Data(Self.card().utf8))
        #expect(c.fields.map(\.id) == ["light", "dark", "light-focus"])
        #expect(c.variants.map(\.id) == [""])
    }

    @Test func factsSayWhatTheMeasurementsSayInWords() throws {
        let c = try JSONDecoder().decode(EvidenceCard.self, from: Data(Self.app.utf8))
        #expect(c.facts("rate-dark") == ["20px wider", "something around it changed too"])
        #expect(c.facts("notes-dark") == ["unchanged"])
    }

    @Test func theSheetOpensOnDarkWhereThemingBugsLive() throws {
        let c = try JSONDecoder().decode(EvidenceCard.self, from: Data(Self.app.utf8))
        let ev = EvidenceState()
        #expect(ev.variant(c) == "dark")
        ev.variant = "light"
        #expect(ev.variant(c) == "light")
        ev.variant = "gone"
        #expect(ev.variant(c) == "dark", "a variant the manifest doesn't have falls back")
    }

    @Test func theChangesOverlayLightsOnlyWhatDiffers() throws {
        func img(_ px: [UInt8]) -> NSImage {
            var b = px
            let ctx = CGContext(data: &b, width: 2, height: 1, bitsPerComponent: 8, bytesPerRow: 8,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            return NSImage(cgImage: ctx.makeImage()!, size: NSSize(width: 2, height: 1))
        }
        let lit = try #require(EvidenceState.lit(img([10, 10, 10, 255, 10, 10, 10, 255]), img([10, 10, 10, 255, 200, 200, 200, 255])))
        let rep = NSBitmapImageRep(data: lit.tiffRepresentation!)!
        #expect(rep.colorAt(x: 1, y: 0)!.redComponent > 0.8, "the changed pixel is gold")
        #expect(rep.colorAt(x: 0, y: 0)!.redComponent < 0.1, "the unchanged pixel is dimmed")
    }

    @Test func theEnginesEligibilityGatesJudgingAndTheClaimIsSaid() throws {
        var c = try JSONDecoder().decode(EvidenceCard.self, from: Data(Self.app.utf8))
        #expect(c.judgeable)
        c.eligible = false
        #expect(!c.judgeable, "a manifest the engine won't let anyone judge can't be judged from canopy either")
        let live = Self.app.replacingOccurrences(of: "\"gaps\":[\"svix\"],", with: "\"gaps\":[\"svix\"],\"claim\":\"live\",")
        let lc = try JSONDecoder().decode(EvidenceCard.self, from: Data(live.utf8))
        #expect(lc.claimWords?.contains("repeatable, not reproducible") == true)
    }

    @Test func evidenceKeysKeepTheRules() throws {
        let (a, _) = try ShipTests().app()
        let v = KeyboardRule.violations(a) { $0.hasPrefix("evidence.") }
        #expect(v.isEmpty, "\(v)")
        #expect(a.registry.keyProblems.isEmpty, "\(a.registry.keyProblems)")
    }
}
