import CanopyCore
import Testing
@testable import CanopyUI

@MainActor @Suite struct ReviewMapTests {
    @Test func mapLabelsFollowTheReviewedBranchAndItsSnapshot() throws {
        let app = world(.review(repo: "r", branch: "f5"), fanIn: true, branchOver: ["f5": ["requires": ["f2", "f3"]]])
        func labels() -> [String: String] {
            Dictionary(uniqueKeysWithValues: ReviewMap.rows(app).compactMap { row in
                row.relationship.map { (row.label, $0) }
            })
        }

        app.keys.handle("space")
        app.keys.handle("m")
        #expect(app.keys.layer == .map)
        #expect(labels() == ["f4": "parent", "f2": "dependency", "f3": "dependency"])

        var branch = try #require(app.store.rawView("branch", "r:f5"))
        branch["requires"] = ["f1", "f4"]
        let version = try #require(app.store.versions[Domain.git])
        #expect(app.store.applyPatch(try Patch.make(domain: Domain.git, version: version + 1,
                                                    upserts: ["branch": ["r:f5": .object(branch)]])) == .ok)
        #expect(labels() == ["f4": "parent", "f1": "dependency"])

        app.keys.handle("k")
        app.keys.handle("ret")
        #expect(app.router.route == .review(repo: "r", branch: "f4"))
        #expect(labels() == ["f1": "parent"])
    }
}
