import CanopyCore
import Foundation
import Testing
@testable import CanopyUI

@MainActor struct ForestAncestryTests {
    let path = "/r/node"
    let reply = #"{"branch":"f5","requires":["f2","f3"],"files":[]}"#

    func app() throws -> (AppModel, Int) {
        ShipTests.nextPort += 1
        let port = ShipTests.nextPort
        let seed = world(.forest(repo: "r", project: "fan"), fanIn: true)
        var config = AppConfig()
        config.route = seed.router.route
        let app = AppModel(config: config, port: port, telemetry: false, protocolClasses: [HeldLookupStub.self, ShipStub.self])
        let body: JSONObject = ["epoch": .string(seed.store.epoch),
                                "versions": .object(seed.store.versions.mapValues { .number(Double($0)) }),
                                "entities": .object(seed.store.raw.mapValues { .object($0) })]
        app.store.hydrate(try Snapshot.decode(JSONEncoder().encode(JSONValue.object(body))))
        app.transport.repos = ["r"]
        app.setCursor("b:r:f5")
        HeldLookupStub.hold(port, path)
        return (app, port)
    }

    func begin(_ app: AppModel, _ port: Int) async throws -> Task<Void, Never> {
        app.runner.dispatch("requires", via: .palette)
        let task = try #require(ForestAncestry.of(app).task)
        await until("the dependency read") { HeldLookupStub.waiting(port, path) }
        return task
    }

    @Test func explicitDependencyRepliesRetainTheirBranchAndPicker() async throws {
        let (app, port) = try app()
        let task = try await begin(app, port)
        HeldLookupStub.release(port, path, reply)
        await task.value
        #expect(app.nav.picker?.items.map(\.label) == ["f4", "f2", "f3"])
        #expect(app.nav.choose(1))
        #expect(app.selected == "b:r:f2")
        #expect(app.nav.reopen())
        #expect(app.nav.choose(0))
        #expect(app.selected == "b:r:f2")
        #expect(KeyboardRule.violations(app) { $0.hasPrefix("forest.") }.isEmpty)
    }

    @Test func movingAwayAndBackBeforeTheTaskStartsSendsNoRead() async throws {
        let (app, port) = try app()
        app.runner.dispatch("requires", via: .palette)
        let task = try #require(ForestAncestry.of(app).task)
        app.moveCursor(1)
        app.moveCursor(-1)
        await task.value
        #expect(!HeldLookupStub.waiting(port, path))
        #expect(app.nav.picker == nil)
        #expect(app.selected == "b:r:f5")
    }

    @Test func aHeldReplyCannotTakeOverAnotherForestOrARepeatVisit() async throws {
        let (app, port) = try app()
        let task = try await begin(app, port)
        app.router.navigate(.forest(repo: "r", project: "tree"))
        app.router.navigate(.forest(repo: "r", project: "fan"))
        HeldLookupStub.release(port, path, reply)
        await task.value
        #expect(app.nav.picker == nil)
        #expect(app.selected == "b:r:f5")
    }

    @Test func aHeldReplyCannotReplaceANewerPicker() async throws {
        let (app, port) = try app()
        let task = try await begin(app, port)
        app.nav.pick("newer", [PickItem(label: "keep this")])
        HeldLookupStub.release(port, path, reply)
        await task.value
        #expect(app.nav.picker?.title == "newer")
    }

    @Test func escapeCancelsTheRead() async throws {
        let (app, port) = try app()
        let task = try await begin(app, port)
        app.keys.handle("esc")
        #expect(app.runner.note == "navigation cancelled")
        HeldLookupStub.release(port, path, reply)
        await task.value
        #expect(!ForestAncestry.of(app).waiting)
        #expect(app.nav.picker == nil)
        #expect(app.selected == "b:r:f5")
    }

    @Test func aGraphChangeAndReturnCannotReviveTheRead() async throws {
        let (app, port) = try app()
        let task = try await begin(app, port)
        let original = try #require(app.store.raw["branch"]?["r:f5"])
        var changed = try #require(original.object)
        changed["tip"] = "new-tip"
        let version = try #require(app.store.versions[Domain.git])
        #expect(app.store.applyPatch(try Patch.make(domain: Domain.git, version: version + 1, upserts: ["branch": ["r:f5": .object(changed)]])) == .ok)
        #expect(app.store.applyPatch(try Patch.make(domain: Domain.git, version: version + 2, upserts: ["branch": ["r:f5": original]])) == .ok)
        HeldLookupStub.release(port, path, reply)
        await task.value
        #expect(app.nav.picker == nil)
    }

    @Test func aGraphChangeInvalidatesAnAlreadyShownPicker() async throws {
        let (app, port) = try app()
        let task = try await begin(app, port)
        HeldLookupStub.release(port, path, reply)
        await task.value
        let version = try #require(app.store.versions[Domain.git])
        #expect(app.store.applyPatch(try Patch.make(domain: Domain.git, version: version + 1, deletes: ["branch": ["r:f2"]])) == .ok)
        #expect(app.nav.choose(1))
        #expect(app.selected == "b:r:f5")
    }

    @Test(arguments: ["{}", #"{"branch":"other","requires":[]}"#, #"{"branch":"f5","err":"unavailable"}"#])
    func failedOrMismatchedRepliesDoNotSilentlyChooseTheParent(_ reply: String) async throws {
        let (app, port) = try app()
        let task = try await begin(app, port)
        HeldLookupStub.release(port, path, reply)
        await task.value
        #expect(app.selected == "b:r:f5")
        #expect(app.nav.picker == nil)
        #expect(app.runner.note?.contains("couldn't read") == true)
    }

    @Test func aRestartWithTheSameGraphCounterDoesNotReviveTheRead() async throws {
        let (app, port) = try app()
        let task = try await begin(app, port)
        let body: JSONObject = ["epoch": "new-server",
                                "versions": .object(app.store.versions.mapValues { .number(Double($0)) }),
                                "entities": .object(app.store.raw.mapValues { .object($0) })]
        app.store.hydrate(try Snapshot.decode(JSONEncoder().encode(JSONValue.object(body))))
        HeldLookupStub.release(port, path, reply)
        await task.value
        #expect(app.nav.picker == nil)
        #expect(app.selected == "b:r:f5")
    }

    @Test func cancellingAnOlderReadDoesNotClearTheNewerOne() async throws {
        let (app, port) = try app()
        let older = try await begin(app, port)
        app.runner.dispatch("requires", via: .palette)
        let newer = try #require(ForestAncestry.of(app).task)
        HeldLookupStub.release(port, path, reply)
        await older.value
        await until("the newer dependency read") { HeldLookupStub.waiting(port, path) }
        #expect(ForestAncestry.of(app).waiting)
        HeldLookupStub.release(port, path, reply)
        await newer.value
        #expect(app.nav.picker?.items.map(\.label) == ["f4", "f2", "f3"])
    }

    @Test func duplicateEdgesDoNotInventAChoice() async throws {
        let (app, port) = try app()
        let task = try await begin(app, port)
        HeldLookupStub.release(port, path, #"{"branch":"f5","requires":["f4","f4"]}"#)
        await task.value
        #expect(app.selected == "b:r:f4")
        #expect(app.nav.picker == nil)
    }

    @Test func theCurrentNodeProducerDoesNotProveAnEmptyDependencyList() async throws {
        let (app, port) = try app()
        let task = try await begin(app, port)
        HeldLookupStub.release(port, path, #"{"branch":"f5","files":[],"dirty":[],"worktree":"","baseSha":"base"}"#)
        await task.value
        #expect(app.selected == "b:r:f5")
        #expect(app.nav.picker == nil)
        #expect(app.runner.note == "dependency edges aren't available from this server")
    }

    @Test func reviewAncestryAlsoRefusesMissingDependencyMetadata() async throws {
        let (app, _) = try await ReviewPageTests().app()
        let pg = ReviewPageState.of(app)
        #expect(pg.payload?.key == pg.keyOf)
        #expect(pg.payload?.data.requires == nil)
        let route = app.router.route
        app.runner.dispatch("requires", via: .palette)
        #expect(app.router.route == route)
        #expect(app.runner.note == "dependency edges aren't available from this server")
    }

    func reviewApp() throws -> AppModel {
        let (app, _) = try app()
        app.router.navigate(.review(repo: "r", branch: "f5"))
        let pg = ReviewPageState.of(app)
        pg.land(pg.keyOf, try JSONValue.object(["branch": "f5", "files": [], "requires": ["f2", "f3"]]).decode(NodePayload.self))
        return app
    }

    @Test func anExplicitReviewDependencyChoiceRemainsReachable() throws {
        let app = try reviewApp()
        app.runner.dispatch("requires", via: .palette)
        #expect(app.nav.picker?.items.map(\.label) == ["f4", "f2", "f3"])
        #expect(app.nav.choose(1))
        #expect(app.router.route.branchID == "r:f2")
    }

    @Test func aReviewDependencyPickerCannotBeReplayedOnAnotherBranch() throws {
        let app = try reviewApp()
        app.runner.dispatch("requires", via: .palette)
        app.nav.close()
        app.router.navigate(.review(repo: "r", branch: "f6"))
        #expect(app.nav.reopen())
        #expect(app.nav.choose(0))
        #expect(app.router.route.branchID == "r:f6")
    }

    @Test func aReviewDependencyChoiceRequiresItsOriginalGraphVersion() throws {
        let app = try reviewApp()
        app.runner.dispatch("requires", via: .palette)
        let version = try #require(app.store.versions[Domain.git])
        #expect(app.store.applyPatch(try Patch.make(domain: Domain.git, version: version + 1, deletes: ["branch": ["r:f2"]])) == .ok)
        #expect(app.nav.choose(0))
        #expect(app.router.route.branchID == "r:f5")
    }

    @Test func missingDependenciesAreReportedInsteadOfDroppingTheirNames() async throws {
        let (app, port) = try app()
        let task = try await begin(app, port)
        HeldLookupStub.release(port, path, #"{"branch":"f5","requires":["missing"]}"#)
        await task.value
        #expect(app.selected == "b:r:f5")
        #expect(app.runner.note == "missing isn't shown in this forest")
    }

    @Test func anUnchangedChildChoiceStillOpensItsBranch() {
        let app = world(.review(repo: "r", branch: "a"))
        app.runner.dispatch("child", via: .palette)
        #expect(app.nav.picker?.items.map(\.label) == ["b", "c"])
        #expect(app.nav.choose(1))
        #expect(app.router.route.branchID == "r:c")
    }

    @Test func anOldChildPickerCannotNavigateFromAnotherReader() {
        let app = world(.review(repo: "r", branch: "a"))
        app.runner.dispatch("child", via: .palette)
        app.nav.close()
        app.router.navigate(.review(repo: "r", branch: "b"))
        #expect(app.nav.reopen())
        #expect(app.nav.choose(1))
        #expect(app.router.route.branchID == "r:b")
    }

    @Test func changingTheGraphInvalidatesTheChildChoices() throws {
        let app = world(.review(repo: "r", branch: "a"))
        app.runner.dispatch("child", via: .palette)
        let version = try #require(app.store.versions[Domain.git])
        #expect(app.store.applyPatch(try Patch.make(domain: Domain.git, version: version + 1, deletes: ["branch": ["r:c"]])) == .ok)
        #expect(app.nav.choose(1))
        #expect(app.router.route.branchID == "r:a")
    }

    @Test func theSameChoiceGuardAllowsTipTraversalPastTheFork() {
        let app = world(.review(repo: "r", branch: "a"))
        app.runner.dispatch("review.tip", via: .palette)
        #expect(app.nav.picker?.items.map(\.label) == ["b", "c"])
        #expect(app.nav.choose(1))
        #expect(app.router.route.branchID == "r:d")
    }
}
