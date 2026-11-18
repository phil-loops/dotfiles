import CanopyCore
import Foundation
import Testing
@testable import CanopyUI

@MainActor @Suite struct ShipControlTests {
    func branch(_ fields: JSONObject = [:]) throws -> Branch {
        let subject = ShipTests()
        let (app, _) = try subject.app { state in
            subject.entity(&state, "branch", ShipTests.branch) { branch in
                branch.merge(fields) { _, new in new }
            }
        }
        return try #require(app.store.view(Branch.self, ShipTests.branch))
    }

    @Test func aSyncedBranchKeepsAnExplicitPushState() throws {
        let branch = try branch(["pushed": "synced", "ahead": 0])
        #expect(ShipControlState.push(branch, route: nil, contextKnown: true) == ShipControlState(enabled: false, reason: "up to date on origin"))
    }

    @Test func missingContextCannotClaimTheBranchIsUpToDate() throws {
        let branch = try branch(["pushed": "synced", "ahead": 0])
        #expect(ShipControlState.push(branch, route: nil, contextKnown: false) == ShipControlState(enabled: false, reason: "branch details unavailable"))
    }

    @Test func aPendingOperationKeepsItsOwnReason() throws {
        let branch = try branch(["pending": "pushing", "pushed": "synced"])
        #expect(ShipControlState.push(branch, route: nil, contextKnown: true).reason == "branch operation pending")
    }

    @Test func noCommitsCannotBecomeAnEnabledPush() throws {
        let branch = try branch(["commits": 0, "pushed": "local"])
        #expect(ShipControlState.push(branch, route: nil, contextKnown: true) == ShipControlState(enabled: false, reason: "no changes to push"))
    }

    @Test(arguments: ["branch.gates.run", "branch.gates.next", "branch.push.arm", "branch.push.confirm", "branch.force.arm", "branch.force.confirm"])
    func anAvailableRouteKeepsItsExistingAction(_ route: String) throws {
        #expect(ShipControlState.push(try branch(), route: route, contextKnown: true) == ShipControlState(enabled: true, reason: nil))
    }

    @Test func aProofBranchStaysVisibleWithoutOfferingAPush() throws {
        let branch = try branch()
        #expect(ShipControlState.push(branch, route: "branch.proof", contextKnown: true) == ShipControlState(enabled: false, reason: "proof branches do not push"))
    }

    @Test func divergenceDoesNotClaimItIsStillChecking() throws {
        let branch = try branch(["diverged": true])
        #expect(ShipControlState.push(branch, route: nil, contextKnown: true) == ShipControlState(enabled: false, reason: "origin replacement unavailable"))
    }

    @Test func aMissingForestKeepsTheUnavailableReasonAndCannotSend() throws {
        let (app, port) = try ShipTests().app { state in
            var entities = state["entities"]!.object!
            entities["project"] = .object([:])
            state["entities"] = .object(entities)
        }
        let branch = try #require(app.store.view(Branch.self, ShipTests.branch))
        #expect(app.forestModel.branchView(branch.id) == nil)
        let route = ReviewCommands.pushRoute(app, branch.id)
        #expect(route == nil)
        #expect(ShipControlState.push(branch, route: route, contextKnown: false).reason == "branch details unavailable")
        app.runner.dispatch("review.push", via: .key, target: branch.id)
        #expect(app.runner.armed == nil)
        #expect(ShipStub.posts(port).isEmpty)
    }

    @Test func theVisiblePushUsesTheExistingConfirmationRoute() throws {
        let subject = ShipTests()
        let (app, port) = try subject.app { state in
            subject.entity(&state, "branch", ShipTests.branch) { branch in
                branch["pushed"] = "ahead"
                branch["ahead"] = 2
                branch["gates"] = "green"
            }
        }
        let branch = try #require(app.store.view(Branch.self, ShipTests.branch))
        #expect(ReviewCommands.pushRoute(app, branch.id) == "branch.push.arm")
        #expect(ShipControlState.push(branch, route: ReviewCommands.pushRoute(app, branch.id), contextKnown: true).enabled)
        app.runner.dispatch("review.push", via: .click, target: branch.id)
        #expect(app.runner.armed == BranchCommands.pushArm(branch.id))
        #expect(ReviewCommands.pushRoute(app, branch.id) == "branch.push.confirm")
        #expect(ShipStub.posts(port).isEmpty)
    }

    /// a first push whose gates hold the door (a follow-up's only advise, and push), its run queued
    /// at #3 behind `ahead` in each tier
    func queued(ahead: [String: Int], tier: String = "background") throws -> (AppModel, Int) {
        let subject = ShipTests()
        return try subject.app { state in
            subject.entity(&state, "branch", ShipTests.branch) { branch in
                branch["pushed"] = "local"
                branch["gates"] = "running"
            }
            let tree = state["entities"]?.object?["branch"]?.object?[ShipTests.branch]?.object?["tree"]?.string ?? ""
            var ents = state["entities"]!.object!
            ents["gaterun"] = .object([ShipTests.branch: .object([
                "id": .string(ShipTests.branch), "branch": .string(ShipTests.branch), "tree": .string(tree), "running": true,
                "started": .number(Date().timeIntervalSince1970 - 5),
                "events": .array([.object(["event": "setup", "step": "queue", "position": 3, "behind": "mine-first",
                                           "tier": .string(tier), "ahead": .object(ahead.mapValues { .number(Double($0)) })])]),
            ])])
            state["entities"] = .object(ents)
        }
    }

    @Test func queuedBehindOnlyYourOwnClicksOffersNoPriority() throws {
        let (app, port) = try queued(ahead: ["interactive": 2, "ship": 0, "background": 0])
        let branch = try #require(app.store.view(Branch.self, ShipTests.branch))
        #expect(BranchCommands.pushRoute(branch.id, app) == nil, "p can't move a run ahead of Phil's own clicks")
        #expect(GatesRun.words(try #require(GatesRun.setup(ShipState.of(app).progressOf(branch.id)))) == "#3 in line · behind 2 yours")
        app.runner.dispatch("review.push", via: .key, target: branch.id)
        #expect(ShipStub.posts(port).isEmpty)
        #expect(GatesRun.nextSaid(was: "interactive", waitingOn: "mine-first") == "already next among yours — waiting on mine-first")
    }

    @Test func aRunningGateKeepsItsPriorityAction() async throws {
        let (app, port) = try queued(ahead: ["interactive": 1, "ship": 0, "background": 1])
        ShipStub.answer(port, "POST", "/loops/gates", #"{"ok":true}"#)
        let branch = try #require(app.store.view(Branch.self, ShipTests.branch))
        let route = ReviewCommands.pushRoute(app, branch.id)
        #expect(route == "branch.gates.next")
        #expect(ShipControlState.push(branch, route: route, contextKnown: true).enabled)
        app.runner.dispatch("review.push", via: .click, target: branch.id)
        await until("the gate priority request") { !ShipStub.posts(port).isEmpty }
        let post = try #require(ShipStub.posts(port).first)
        #expect(post.path == "/loops/gates")
        #expect(post.body["next"] == true)
        #expect(ShipStub.posts(port).count == 1)
    }
}
