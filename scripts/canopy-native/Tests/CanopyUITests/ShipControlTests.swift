import CanopyTestSupport
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

    /// The push button for a branch with these fields, as the strip builds it: its route, else its situation's sentence.
    func control(_ fields: JSONObject) throws -> ShipControlState {
        let subject = ShipTests()
        let (app, _) = try subject.app { state in
            subject.entity(&state, "branch", ShipTests.branch) { branch in branch.merge(fields) { _, new in new } }
        }
        let v = try #require(app.forestModel.branchView(ShipTests.branch))
        return ShipControlState.push(route: ReviewCommands.pushRoute(app, v.b.id), situation: ShipRules.says(v.st, v.b, v.pr))
    }

    @Test func aSyncedBranchSaysItsNextStepNotAPushState() throws {
        // the fixture's PR has changes requested: that, not a push state, is what the button says
        let c = try control(["pushed": "synced", "ahead": 0, "gates": "green"]); #expect(c == ShipControlState(enabled: false, reason: "changes requested"), "\(c)")
    }

    @Test func missingContextCannotClaimTheBranchIsUpToDate() {
        #expect(ShipControlState.push(route: nil, situation: nil) == ShipControlState(enabled: false, reason: "branch details unavailable"))
    }

    @Test func aPendingOperationSaysSo() throws {
        #expect(try control(["pending": "pushing", "pushed": "synced"]).reason == "pushing…")
    }

    @Test func noCommitsCannotBecomeAnEnabledPush() throws {
        let c = try control(["commits": 0, "pushed": "local"]); #expect(!c.enabled, "\(c)")
    }

    @Test(arguments: ["branch.gates.run", "branch.gates.next", "branch.push.arm", "branch.push.confirm", "branch.force.arm", "branch.force.confirm"])
    func anAvailableRouteKeepsItsExistingAction(_ route: String) {
        #expect(ShipControlState.push(route: route, situation: "x") == ShipControlState(enabled: true, reason: nil))
    }

    @Test func aProofBranchStaysVisibleWithoutOfferingAPush() {
        #expect(ShipControlState.push(route: "branch.proof", situation: "proof run green") == ShipControlState(enabled: false, reason: "proof branches do not push"))
    }

    @Test func divergenceWithNoReadSaysItIsReading() throws {
        #expect(try control(["diverged": true, "pushed": "ahead", "ahead": 1]) == ShipControlState(enabled: false, reason: "reading origin…"))
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
        #expect(ShipControlState.push(route: route, situation: nil).reason == "branch details unavailable")
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
        #expect(ShipControlState.push(route: ReviewCommands.pushRoute(app, branch.id), situation: nil).enabled)
        app.runner.dispatch("review.push", via: .click, target: branch.id)
        #expect(app.runner.armed == BranchCommands.pushArm(branch.id, branch.tip))
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

    @Test func queuedBehindYourOwnClicksStillPutsItNext() throws {
        let (app, port) = try queued(ahead: ["interactive": 2, "ship": 0, "background": 0], tier: "interactive")
        ShipStub.answer(port, "POST", "/loops/gates", #"{"ok":true,"next":true}"#)
        let branch = try #require(app.store.view(Branch.self, ShipTests.branch))
        #expect(BranchCommands.pushRoute(branch.id, app) == "branch.gates.next", "p moves a run ahead of Phil's earlier clicks too")
        #expect(GatesRun.words(try #require(GatesRun.setup(ShipState.of(app).progressOf(branch.id)))) == "#3 in line · behind 2 yours · p puts it next")
    }

    @Test func aRunFirstInLineOffersNoPriority() throws {
        let subject = ShipTests()
        let (app, _) = try subject.app { state in
            subject.entity(&state, "branch", ShipTests.branch) { branch in
                branch["pushed"] = "local"
                branch["gates"] = "running"
            }
            let tree = state["entities"]?.object?["branch"]?.object?[ShipTests.branch]?.object?["tree"]?.string ?? ""
            var ents = state["entities"]!.object!
            ents["gaterun"] = .object([ShipTests.branch: .object([
                "id": .string(ShipTests.branch), "branch": .string(ShipTests.branch), "tree": .string(tree), "running": true,
                "started": .number(Date().timeIntervalSince1970 - 5),
                "events": .array([.object(["event": "setup", "step": "queue", "position": 1, "behind": "other",
                                           "tier": "interactive", "ahead": .object([:])])]),
            ])])
            state["entities"] = .object(ents)
        }
        let branch = try #require(app.store.view(Branch.self, ShipTests.branch))
        #expect(BranchCommands.pushRoute(branch.id, app) == "branch.push.queue",
                "first in line: p can't pass the running run, so it queues the push for green (Phil 2026-11-18)")
    }

    @Test func aRunningGateKeepsItsPriorityAction() async throws {
        let (app, port) = try queued(ahead: ["interactive": 1, "ship": 0, "background": 1])
        ShipStub.answer(port, "POST", "/loops/gates", #"{"ok":true}"#)
        let branch = try #require(app.store.view(Branch.self, ShipTests.branch))
        let route = ReviewCommands.pushRoute(app, branch.id)
        #expect(route == "branch.gates.next")
        #expect(ShipControlState.push(route: route, situation: nil).enabled)
        app.runner.dispatch("review.push", via: .click, target: branch.id)
        await until("the gate priority request") { !ShipStub.posts(port).isEmpty }
        let post = try #require(ShipStub.posts(port).first)
        #expect(post.path == "/loops/gates")
        #expect(post.body["next"] == true)
        #expect(ShipStub.posts(port).count == 1)
    }
}

@MainActor @Suite struct ChatSituationTests {
    /// The fixture branch, local and building, with one chat that committed to it `ago` seconds after its last tool call.
    func stand(chatIdleFor idle: Double) throws -> Stand {
        let now = Date().timeIntervalSince1970
        let (app, _) = try ShipTests().app { state in
            var ents = state["entities"]!.object!
            var table = ents["pr"]?.object ?? [:]
            table.removeValue(forKey: ShipTests.branch)
            ents["pr"] = .object(table)
            ents["chat"] = .object(["c1": .object([
                "id": "c1abcdef-0000", "generation": 1, "activeAt": .number(now - idle), "works": .array([]),
                "acted": .array([.object(["branch": .string(ShipTests.branch), "how": "commit", "at": .number(now - idle)])])])])
            state["entities"] = .object(ents)
            ShipTests().entity(&state, "branch", ShipTests.branch) { $0["gates"] = "stale"; $0["pushed"] = "local" }
        }
        return try #require(app.forestModel.branchView(ShipTests.branch)).st
    }

    @Test func aLiveChatOnTheBranchHoldsItsMove() throws {
        #expect(try stand(chatIdleFor: 10).actor == .agent("chat c1abcdef"))
    }

    /// Round 29: an idle chat's reply is owed once, on the home's reply line — never by each branch it touched.
    @Test func anIdleChatHandsNoBranchBack() throws {
        let st = try stand(chatIdleFor: 600)
        #expect(st.awaiting == nil && st.actor == .building, "the branch's own route decides it again")
    }
}
