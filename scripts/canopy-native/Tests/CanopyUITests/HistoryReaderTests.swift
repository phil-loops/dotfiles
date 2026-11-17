import CanopyCore
import Foundation
import Testing
@testable import CanopyUI

@MainActor struct HistoryReaderTests {
    @Test func aFailedReaderOffersAnExactNamedRetryAndRecovers() async throws {
        let app = world(.review(repo: "r", branch: "b"))
        let history = BranchHistory.of(app)
        history.read = { _ in throw Refusal("recorded unavailable") }
        await history.load("r:b", retry: true)?.value
        let ship = ShipState.of(app)
        #expect(ship.historyNote("r:b") == "couldn't read the commits · :review.commits.retry")
        app.runner.dispatch("review.line", via: .key)
        #expect(app.runner.note == ship.historyNote("r:b"))
        #expect(app.registry.command("review.commits.retry")?.available?(nil) == true)
        history.read = { _ in [] }
        app.runner.dispatch("review.commits.retry", via: .palette)
        await history.load("r:b")?.value
        #expect(ship.historyRows("r:b") == [])
        #expect(ReviewPageState.of(app).line != nil)
        #expect(app.registry.command("review.commits.retry")?.available?(nil) == false)
        #expect(KeyboardRule.violations(app) { $0 == "review.commits.retry" }.isEmpty)
    }

    @Test func aParentUpdateCannotRetargetThePickedEndpointByIndex() throws {
        let app = world(.review(repo: "r", branch: "b"))
        let pg = ReviewPageState.of(app)
        let ship = ShipState.of(app)
        let branch = try #require(pg.branch)
        ship.putHistory(branch, [HistoryCommit(sha: "c3", subject: "Third"), HistoryCommit(sha: "c2", subject: "Second"), HistoryCommit(sha: "c1", subject: "First")])
        app.runner.dispatch("review.line", via: .key)
        app.setCursor("c|c2")
        app.runner.dispatch("line.pick", via: .key)
        #expect(pg.lineAnchor == pg.line?.index(sha: "c2"))
        var parent = try #require(app.store.raw["branch"]?["r:a"]?.object)
        parent["tip"] = "c1"
        #expect(app.store.applyPatch(try Patch.make(domain: Domain.git, version: (app.store.versions[Domain.git] ?? 0) + 1,
                                                  upserts: ["branch": ["r:a": .object(parent)]])) == .ok)
        #expect(pg.lineAnchor == nil, "the pick bound to rows read before the parent moved")
        #expect(ship.historyRows(branch.id) != nil && BranchHistory.of(app).isStale(branch.id), "those rows still draw, marked stale")
        ship.putHistory(branch, [HistoryCommit(sha: "c3", subject: "Third"), HistoryCommit(sha: "c2", subject: "Second")])
        #expect(pg.lineAnchor == nil)
        app.setCursor("c|c2")
        app.runner.dispatch("line.pick", via: .key)
        #expect(pg.commitScope == nil)
        #expect(pg.lineAnchor == pg.line?.index(sha: "c2"))
        app.runner.dispatch("line.pick", via: .key)
        #expect(pg.commitScope == "c2")
    }

    @Test func aDefaultStretchBranchRoundTripCannotRestoreAnOldPendingEndpoint() throws {
        let app = world(.review(repo: "r", branch: "b"))
        let pg = ReviewPageState.of(app)
        pg.sync()
        let b = try #require(pg.branch)
        let c = try #require(app.store.view(Branch.self, "r:c"))
        let ship = ShipState.of(app)
        ship.putHistory(b, [HistoryCommit(sha: "b2", subject: "B2"), HistoryCommit(sha: "b1", subject: "B1")])
        ship.putHistory(c, [HistoryCommit(sha: "c1", subject: "C1")])
        pg.lineAnchor = pg.line?.index(sha: "b1")
        #expect(pg.lineAnchor != nil)
        let stamp = BranchHistory.of(app).stamp(b.id)
        app.router.navigate(.review(repo: "r", branch: "c")); pg.sync()
        #expect(pg.lineAnchor == nil)
        app.router.navigate(.review(repo: "r", branch: "b")); pg.sync()
        #expect(BranchHistory.of(app).stamp(b.id) == stamp)
        #expect(pg.lineAnchor == nil)
    }

    @Test func replacingAReadAtTheSameSourceAlsoRevokesItsPendingChoice() throws {
        let app = world(.review(repo: "r", branch: "b"))
        let pg = ReviewPageState.of(app)
        let branch = try #require(pg.branch)
        let ship = ShipState.of(app)
        ship.putHistory(branch, [HistoryCommit(sha: "c2", subject: "Second"), HistoryCommit(sha: "c1", subject: "First")])
        pg.lineAnchor = pg.line?.index(sha: "c1")
        #expect(pg.lineAnchor != nil)
        ship.putHistory(branch, [HistoryCommit(sha: "c3", subject: "Third"), HistoryCommit(sha: "c2", subject: "Second"), HistoryCommit(sha: "c1", subject: "First")])
        #expect(pg.lineAnchor == nil)
        var stale = branch; stale.tip = "older"
        ship.putHistory(stale, [HistoryCommit(sha: "obsolete", subject: "Obsolete")])
        #expect(ship.historyRows(branch.id)?.first?.sha == "c3")
    }
}
