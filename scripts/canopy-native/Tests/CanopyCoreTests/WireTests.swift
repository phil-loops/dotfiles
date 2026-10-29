import Foundation
import Testing
@testable import CanopyCore

func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

@Suite struct WireTests {
    @Test func decodesARealStateSnapshot() throws {
        let s = try Snapshot.decode(fixture("state.json"))
        #expect(s.entities.failures.isEmpty, "\(s.entities.failures)")
        #expect(s.versions["git"] == 21)
        #expect(s.entities.repo.values["loops"]?.main == "main")
        let b = try #require(s.entities.branch.values["loops:add-hankles-limited-label"])
        #expect(b.project == "loops:hankles-limited-label")
        #expect(b.gates == .green || !b.gates.rawValue.isEmpty)
        let conv = try #require(s.entities.conv.values["loops:add-hankles-limited-label"])
        #expect(conv.number == 11285)
        #expect(s.entities.thread.values.values.allSatisfy { !$0.comments.isEmpty })
        #expect(!s.entities.todo.values.isEmpty)
        // every raw table the server sent is kept, typed or not
        #expect(Set(s.raw.keys) == Set(EntityType.allCases.map(\.rawValue)))
        #expect(s.raw["branch"]?.count == s.entities.branch.values.count)
    }

    @Test func oneBadEntityDoesNotDropTheTable() throws {
        let json = #"{"epoch":"e","versions":{"git":1},"entities":{"repo":{"a":{"id":"a","name":"a","main":"main","trunk":"x"},"b":{"id":"b"}}}}"#
        let s = try Snapshot.decode(Data(json.utf8))
        #expect(s.entities.repo.values.keys.sorted() == ["a"])
        #expect(s.entities.failures.count == 1)
        #expect(s.raw["repo"]?.count == 2)
    }

    @Test func openStringsKeepUnknownValues() throws {
        let b = try JSONDecoder().decode(Gates.self, from: Data(#""purple""#.utf8))
        #expect(b.rawValue == "purple")
        #expect(Gates.green == "green")
    }

    @Test func sseFramesFromTheFixture() throws {
        let text = String(decoding: try fixture("events.sse"), as: UTF8.self)
        let frames = SSEParser.frames(in: text)
        #expect(frames.map(\.event) == ["hello", "patch", "patch", "resync"])
        #expect(frames[0].json?["asset"]?.string?.isEmpty == false)
        let p = try Patch.decode(Data(frames[1].data.utf8))
        #expect(p.domain == "git")
        #expect(p.version == 20)
        #expect(p.upserts.branch.values.count == 1)
    }

    @Test func sseParserJoinsDataAndSkipsComments() {
        var p = SSEParser()
        #expect(p.feed(line: ": ping") == nil)
        #expect(p.feed(line: "") == nil)
        #expect(p.feed(line: "data: a") == nil)
        #expect(p.feed(line: "data:b\r") == nil)
        #expect(p.feed(line: "") == SSEFrame(event: "message", data: "a\nb"))
    }

    @Test func versionCheck() throws {
        let have: Versions = ["git": 3]
        #expect(checkVersion(have, try Patch.make(domain: "git", version: 4)) == .ok)
        #expect(checkVersion(have, try Patch.make(domain: "git", version: 6)) == .gap)
        #expect(checkVersion(have, try Patch.make(domain: "git", version: 3)) == .stale)
        #expect(checkVersion(have, try Patch.make(domain: "newdomain", version: 1)) == .ok)
    }

    @Test func bootstrapFromTheInjectedScript() {
        let html = #"<html><head><script>window.__VIEWER_REPOS__=["loops", "monotoad"];window.__CANOPY_KEYS__={"keys": {"undo": ["U"]}, "errors": []};window.__CANOPY_ASSET__="abc123"</script></head></html>"#
        let b = Bootstrap.parse(html: html)
        #expect(b == Bootstrap(repos: ["loops", "monotoad"], keys: ["undo": ["U"]], keyErrors: [], asset: "abc123"))
        #expect(Bootstrap.parse(html: "<html></html>") == nil)
    }

    @Test func keysTomlFallback() {
        let (keys, errors) = KeysToml.parse("""
        # comment
        "project.archive" = "x"
        "review.extend" = ["v", "x"]   # trailing
        "hold.morning" = []
        "bad" = 3
        """)
        #expect(keys == ["project.archive": ["x"], "review.extend": ["v", "x"], "hold.morning": []])
        #expect(errors == ["bad: wants a key or a list of keys"])
    }
}
