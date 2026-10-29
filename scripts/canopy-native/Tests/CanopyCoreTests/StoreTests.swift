import Foundation
import Testing
@testable import CanopyCore

let branchJSON: JSONObject = [
    "id": "loops:x", "repo": "loops", "name": "x", "project": "loops:p", "parent": "main", "parentId": nil,
    "description": "does x", "subject": "feat: x", "commits": 1, "outline": ["feat: x"], "tip": "t", "tree": "r",
    "pushed": "local", "ahead": 0, "gates": "none", "redGates": [], "order": 1, "holdUntil": nil, "behind": 0,
    "drifted": false, "upstream": "", "upstreamBad": false, "diverged": false,
]

@MainActor @Suite struct StoreTests {
    func hydrated(git: Int = 19) throws -> Store {
        let s = Store()
        var snap = try Snapshot.decode(fixture("state.json"))
        snap.versions["git"] = git
        s.hydrate(snap)
        return s
    }

    @Test func hydrateFillsTablesAndCallsListeners() throws {
        let s = Store()
        var calls = 0
        _ = s.onChange { calls += 1 }
        s.hydrate(try Snapshot.decode(fixture("state.json")))
        #expect(s.ready)
        #expect(s.epoch == "131f86ae3771c")
        #expect(s.branch.count == 2)
        #expect(s.counts["landed"] == 3)
        #expect(calls == 1)
    }

    @Test func appliesFixturePatchesInOrderThenRefusesAReplay() throws {
        let s = try hydrated()
        let frames = SSEParser.frames(in: String(decoding: try fixture("events.sse"), as: UTF8.self)).filter { $0.event == "patch" }
        let p1 = try Patch.decode(Data(frames[0].data.utf8)), p2 = try Patch.decode(Data(frames[1].data.utf8))
        #expect(s.applyPatch(p1) == .ok)
        #expect(s.applyPatch(p2) == .ok)
        #expect(s.versions["git"] == 21)
        #expect(s.applyPatch(p2) == .stale)
    }

    @Test func gapIsNotApplied() throws {
        let s = try hydrated()
        var b = branchJSON
        b["id"] = "loops:new"
        let p = try Patch.make(domain: "git", version: 25, upserts: ["branch": ["loops:new": .object(b)]])
        #expect(s.applyPatch(p) == .gap)
        #expect(s.branch["loops:new"] == nil)
        #expect(s.versions["git"] == 19)
    }

    @Test func upsertsAndDeletesTypedAndRaw() throws {
        let s = try hydrated()
        let p = try Patch.make(domain: "git", version: 20, upserts: ["branch": ["loops:x": .object(branchJSON)]],
                               deletes: ["branch": ["loops:add-email-reading-format"]])
        #expect(s.applyPatch(p) == .ok)
        #expect(s.branch["loops:x"]?.description == "does x")
        #expect(s.branch["loops:add-email-reading-format"] == nil)
        #expect(s.raw["branch"]?["loops:add-email-reading-format"] == nil)
        #expect(s.raw["branch"]?["loops:x"]?["subject"] == "feat: x")
    }

    @Test func undecodableUpsertRemovesTheStaleTypedCopy() throws {
        let s = try hydrated()
        let p = try Patch.make(domain: "git", version: 20, upserts: ["branch": ["loops:add-email-reading-format": ["id": "broken"]]])
        #expect(s.applyPatch(p) == .ok)
        #expect(s.branch["loops:add-email-reading-format"] == nil)
        #expect(s.raw["branch"]?["loops:add-email-reading-format"]?["id"] == "broken")
        #expect(!s.decodeFailures.isEmpty)
    }

    @Test func overlayShowsUntilDropped() throws {
        let s = try hydrated()
        let id = "loops:add-hankles-limited-label"
        let before = try #require(s.view(Branch.self, id))
        s.addOps([Op(seq: 7, type: .branch, id: id, fields: ["pending": "pushing", "description": "optimistic"])])
        #expect(s.view(Branch.self, id)?.pending == "pushing")
        #expect(s.view(Branch.self, id)?.description == "optimistic")
        #expect(s.rawView("branch", id)?["pending"] == "pushing")
        #expect(s.table(Branch.self)[id]?.description == before.description)
        s.dropOps(seq: 7)
        #expect(s.view(Branch.self, id) == before)
    }

    @Test func unknownEntityTypesStayRaw() throws {
        let s = try hydrated()
        let p = try Patch.make(domain: "git", version: 20, upserts: ["gizmo": ["g1": ["id": "g1", "n": 3]]])
        #expect(s.applyPatch(p) == .ok)
        #expect(s.raw["gizmo"]?["g1"]?["n"]?.int == 3)
    }
}
