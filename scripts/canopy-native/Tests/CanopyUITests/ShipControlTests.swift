import CanopyCore
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

    @Test func aRunningGateKeepsItsPriorityAction() async throws {
        let subject = ShipTests()
        let (app, port) = try subject.app { state in
            // a first push: its gates hold the door (a follow-up's only advise, and push)
            subject.entity(&state, "branch", ShipTests.branch) { branch in
                branch["pushed"] = "local"
                branch["gates"] = "running"
            }
        }
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
