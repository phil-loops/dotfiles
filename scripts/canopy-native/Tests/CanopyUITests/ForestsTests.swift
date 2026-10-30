import CanopyCore
import Foundation
import Testing
@testable import CanopyUI

// The forests area: ship.test.ts and loop.test.ts as they are, then the pages and their keys end to
// end through the real registry over a small world — no network (port 1), writes inspected as the
// `Write` they'd post, never sent anywhere live.

private func decode<T: Decodable>(_ obj: [String: Any]) -> T {
    try! JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: obj))
}

private func brObj(_ over: [String: Any] = [:]) -> [String: Any] {
    var o: [String: Any] = [
        "id": "r:b", "repo": "r", "name": "f/b", "project": "r:f", "parent": "main", "parentId": NSNull(), "description": "", "subject": "s",
        "commits": 1, "outline": ["s"], "tip": "t", "tree": "x", "pushed": "local", "ahead": 0, "gates": "none", "redGates": [String](), "order": 1,
        "holdUntil": NSNull(), "behind": 0, "drifted": false, "upstream": "", "upstreamBad": false, "diverged": false,
    ]
    for (k, v) in over { o[k] = v }
    return o
}

private func prObj(_ over: [String: Any] = [:]) -> [String: Any] {
    var o: [String: Any] = [
        "id": "r:b", "repo": "r", "branch": "f/b", "project": "r:f", "number": 7, "url": "u", "state": "OPEN", "review": NSNull(), "draft": false,
        "base": NSNull(), "approvals": NSNull(), "mergeState": NSNull(), "mergeable": NSNull(), "approvedAt": NSNull(), "title": NSNull(),
    ]
    for (k, v) in over { o[k] = v }
    return o
}

private func br(_ over: [String: Any] = [:]) -> Branch { decode(brObj(over)) }
private func pr(_ over: [String: Any] = [:]) -> Pr { decode(prObj(over)) }
private func iso(_ s: String) -> Date { parseISO(s)! }

private let NOW = iso("2026-10-22T18:00:00Z") // Thu 11:00 PT

@Suite struct ShipRulesTests {
    func stand(_ b: Branch, _ p: Pr? = nil, _ parent: ParentStand? = nil, _ now: Date = NOW) -> Stand { ShipRules.stand(b, p, parent, now: now) }

    @Test func eachShipStageHasOneActionOnReturn() {
        #expect(stand(br()).ship == .local && stand(br()).action == .open)
        #expect(stand(br(["gates": "green"])).action == .push)
        #expect(stand(br(["gates": "green", "pushed": "synced"])).action == .pr)
        #expect(stand(br(), pr()).ship == .review)
        #expect(stand(br(), pr(["review": "APPROVED"])).ship == .approved)
        #expect(stand(br(), pr(["state": "MERGED"])).ship == .landed)
    }

    @Test func readyMeansYouCanActNow() {
        let localParent = ParentStand(ship: .green, name: "f/a")
        #expect(stand(br(["gates": "green"])).ready)
        #expect(!stand(br(["gates": "green"]), nil, localParent).ready)
        #expect(stand(br(["gates": "green"]), nil, ParentStand(ship: .pushed, name: "f/a")).ready)
        #expect(stand(br(["pushed": "synced"])).ready)
        #expect(!stand(br(), pr()).ready)
        let appr = pr(["review": "APPROVED", "mergeState": "CLEAN"])
        #expect(stand(br(), appr).ready)
        #expect(stand(br(), appr).waiting.first?.kind == .merge)
        let waits = stand(br(), appr, ParentStand(ship: .review, pr: pr(["number": 3]), name: "f/a"))
        #expect(!waits.ready && waits.waiting.first?.label == "parent #3 to merge")
        #expect(stand(br(), appr, ParentStand(ship: .landed, name: "f/a")).ready)
    }

    @Test func aHoldKeepsABranchOutOfReadyUntilDue() {
        let held = br(["gates": "green", "holdUntil": "2026-10-23T16:00:00Z"])
        #expect(stand(held).held && !stand(held).ready)
        let due = stand(held, nil, nil, iso("2026-10-23T16:05:00Z"))
        #expect(!due.held && due.ready)
    }

    @Test func aCompareLinkStacksOnAnUnlandedParent() {
        #expect(ShipRules.baseFor(br(), ParentStand(ship: .pushed, name: "f/a"), trunk: "main") == "f/a")
        #expect(ShipRules.baseFor(br(), ParentStand(ship: .landed, name: "f/a"), trunk: "main") == "main")
        #expect(ShipRules.baseFor(br(), nil, trunk: "main") == "main")
    }

    @Test func aForestClosesWhenEverythingLanded() {
        #expect(ShipRules.isClosed([.landed, .landed]))
        #expect(!ShipRules.isClosed([.landed, .approved]))
        #expect(!ShipRules.isClosed([]))
    }

    @Test func thePushWindowSpeaksOnlyNearAndAfterTheCliff() {
        #expect(PushWindow.line(NOW) == "")
        #expect(PushWindow.phaseAt(iso("2026-10-22T21:30:00Z")).phase == .closing)
        #expect(PushWindow.line(iso("2026-10-22T21:30:00Z")).hasPrefix("30m to 3pm"))
        let late = PushWindow.line(iso("2026-10-22T23:00:00Z"))
        #expect(late.hasPrefix("past 3pm ") && late.hasSuffix(" from Fri 9am"), "\(late)")
        #expect(PushWindow.line(iso("2026-10-24T18:00:00Z")).hasSuffix("until Mon 9am"))
        #expect(isoString(PushWindow.nextMorning(iso("2026-10-23T23:00:00Z"))) == "2026-10-26T16:00:00.000Z")
    }

    @Test func pPushesFollowUpsOntoAnOpenPR() {
        let open = pr(["state": "OPEN", "review": "APPROVED"])
        #expect(ShipRules.canPush(br(["gates": "green", "pushed": "ahead", "ahead": 2, "commits": 5]), open))
        #expect(ShipRules.canPush(br(["gates": "green", "pushed": "local"]), nil))
        #expect(!ShipRules.canPush(br(["gates": "stale", "pushed": "ahead", "ahead": 2]), open))
        #expect(!ShipRules.canPush(br(["gates": "green", "pushed": "synced"]), open))
        #expect(!ShipRules.canPush(br(["gates": "green", "pushed": "ahead", "ahead": 1, "pending": "pushing"]), open))
    }
}

@Suite struct LoopTests {
    func at(_ b: Branch, _ p: Pr? = nil, words: [LoopWord]? = []) -> String {
        let steps = Loop.steps(b, p, ShipRules.stand(b, p, nil, now: NOW), words: words)
        guard let now = steps.filter({ $0.id != .words }).first(where: { $0.state == .now }) else { return "done" }
        return now.id.rawValue + (now.note.map { " \($0)" } ?? "")
    }

    @Test func theStepInTheWayWithWhatItWaitsOn() {
        #expect(at(br()) == "gates not run")
        #expect(at(br(["gates": "running"])) == "gates running")
        #expect(at(br(["gates": "red", "redGates": ["typecheck"]])) == "gates typecheck")
        #expect(at(br(["gates": "green"])) == "push 1 local")
        #expect(at(br(["gates": "green", "pushed": "synced"])) == "pr open it")
        #expect(at(br(["gates": "green", "pushed": "synced"]), pr()) == "review waiting")
        #expect(at(br(["gates": "green", "pushed": "synced"]), pr(["review": "APPROVED"])) == "merged you — merge it")
        #expect(at(br(["pushed": "synced"]), pr(["state": "MERGED"])) == "done")
    }

    @Test func newCommitsOnAnOpenPRSendTheLoopBackToGates() {
        #expect(at(br(["pushed": "ahead", "ahead": 2, "gates": "stale"]), pr()) == "gates stale")
        #expect(at(br(["pushed": "ahead", "ahead": 2, "gates": "green"]), pr()) == "push 2 to push")
    }

    @Test func wordsFlagWithoutBlocking() {
        let scope = [LoopWord(id: "scope", tone: "warn")]
        func words(_ b: Branch, _ p: Pr? = nil) -> LoopStep { Loop.steps(b, p, ShipRules.stand(b, p, nil, now: NOW), words: scope)[0] }
        #expect(words(br(["gates": "green"])) == LoopStep(id: .words, state: .now, note: "scope", flag: true))
        #expect(at(br(["gates": "green"])) == "push 1 local")
        #expect(words(br(["pushed": "synced"]), pr()).state == .done)
    }

    @Test func unreadWordsLeaveTheStepOut() {
        let b = br(["gates": "green"])
        #expect(Loop.steps(b, nil, ShipRules.stand(b, nil, nil, now: NOW), words: nil).map(\.id) == [.gates, .push, .pr, .review, .merged])
    }
}

@Suite struct StoryTextTests {
    @Test func bareDropsTheConventionalPrefix() {
        #expect(OutlineHints.bare("feat(goals-metrics-ui-job): the main job") == "the main job")
        #expect(OutlineHints.bare("Fix!: loud") == "loud")
        #expect(OutlineHints.bare("plain subject") == "plain subject")
    }

    @Test func stripPlanDropsTheGeneratedBlock() {
        let body = "the why\n\nPart of a stack:\n  1. a\n  2. b\n\n  3. c\n\n-- forest --\nafter"
        #expect(OutlineHints.stripPlan(body) == "the why\n\nafter")
    }
}

// ── the pages, end to end ──

/// A small world: two focus forests (the first a fork: a → b, a → c, c → d), one on the workbench,
/// one archived, one whose every PR landed.
@MainActor
private func world(_ route: Route = .forests) -> AppModel {
    var c = AppConfig()
    c.route = route
    let a = AppModel(config: c, port: 1, telemetry: false)
    func project(_ name: String, _ state: String, rank: Int? = nil) -> (String, [String: Any]) {
        ("r:\(name)", ["id": "r:\(name)", "repo": "r", "name": name, "state": state, "rank": rank as Any? ?? NSNull(), "ticket": NSNull(),
                       "summary": "\(name) summary", "size": 1])
    }
    func branch(_ name: String, _ proj: String, order: Int, parent: String? = nil, _ over: [String: Any] = [:]) -> (String, [String: Any]) {
        var o = brObj(["id": "r:\(name)", "name": name, "project": "r:\(proj)", "order": order, "description": "\(name) does it",
                       "parent": parent ?? "main", "parentId": parent.map { "r:\($0)" } as Any? ?? NSNull()])
        for (k, v) in over { o[k] = v }
        return ("r:\(name)", o)
    }
    let projects = Dictionary(uniqueKeysWithValues: [
        project("tree", "focus", rank: 1), project("solo", "focus", rank: 2), project("bench", "workbench"),
        project("old", "archive"), project("done", "workbench"),
    ])
    let branches = Dictionary(uniqueKeysWithValues: [
        branch("a", "tree", order: 1, ["gates": "green", "pushed": "synced"]),
        branch("b", "tree", order: 2, parent: "a", ["gates": "green"]),
        branch("c", "tree", order: 3, parent: "a"),
        branch("d", "tree", order: 4, parent: "c"),
        branch("s", "solo", order: 1, ["gates": "green", "commits": 2]),
        branch("w", "bench", order: 1),
        branch("o", "old", order: 1),
        branch("x", "done", order: 1, ["pushed": "synced"]),
    ])
    let prs: [String: Any] = [
        "r:a": prObj(["id": "r:a", "branch": "a", "project": "r:tree", "number": 11]),
        "r:x": prObj(["id": "r:x", "branch": "x", "project": "r:done", "number": 12, "state": "MERGED"]),
    ]
    let landed: [String: Any] = ["r:tree#9": ["id": "r:tree#9", "repo": "r", "project": "r:tree", "pr": 9, "title": "feat: the ground", "branch": "z", "at": "2026-10-01T10:00:00Z"]]
    let state: [String: Any] = [
        "epoch": "e", "versions": ["git": 1, "remote": 1, "review": 1, "todo": 1],
        "entities": ["repo": ["r": ["id": "r", "name": "r", "main": "main", "trunk": "abc"]], "project": projects, "branch": branches, "pr": prs, "landed": landed],
    ]
    a.store.hydrate(try! Snapshot.decode(JSONSerialization.data(withJSONObject: state)))
    a.forestModel.now = NOW
    a.forestModel.face = .branches
    return a
}

@MainActor @Suite(.serialized) struct ForestsPageTests {
    @Test func keysFollowTheMouselessRule() {
        let a = world()
        let mine = ["project.", "forest.", "forests.", "focus.", "branch.", "hold.", "story.", "ready.", "archive.", "row.primary"]
        let v = KeyboardRule.violations(a) { id in mine.contains { id.hasPrefix($0) } }
        #expect(v.isEmpty, "\(v)")
        #expect(a.registry.keyProblems.isEmpty, "\(a.registry.keyProblems)")
    }

    @Test func homeRowsAreFocusThenWorkbenchWithTheArchiveFolded() {
        let a = world()
        a.forestModel.syncClosings()
        // `done` is closed (every PR landed), so it's shelved into the archive fold
        #expect(a.rows == ["p:r:tree", "p:r:solo", "p:r:bench"])
        a.keys.handle(","); a.keys.handle("a")
        #expect(a.rows == ["p:r:tree", "p:r:solo", "p:r:bench", "p:r:done", "p:r:old"])
        #expect(ForestNav.primary(for: "p:r:old", a)?.id == "project.restore")
        #expect(ForestNav.primary(for: "p:r:done", a)?.id == "project.archive")
    }

    @Test func lOpensTheSpineThenThePageAndHFolds() {
        let a = world()
        a.keys.handle("l")
        #expect(a.rows.prefix(5) == ["p:r:tree", "b:r:a", "b:r:b", "b:r:c", "b:r:d"])
        a.keys.handle("j"); a.keys.handle("j")
        #expect(a.selected == "b:r:b")
        a.keys.handle("h")
        #expect(a.selected == "p:r:tree" && !a.forestModel.expanded.contains("r:tree"))
        a.keys.handle("l"); a.keys.handle("l")
        #expect(a.router.route == .forest(repo: "r", project: "tree"))
        #expect(a.selected == "b:r:a")
    }

    @Test func retDoesTheRowsThing() {
        let a = world()
        a.keys.handle("ret")
        #expect(a.router.route == .forest(repo: "r", project: "tree"))
        a.keys.handle("h")
        #expect(a.router.route == .forests && a.selected == "p:r:tree", "h lands on Forests with the cursor on this forest")
    }

    @Test func theReadyFilterShowsOnlyWhatsReady() {
        let a = world()
        a.keys.handle(","); a.keys.handle("r")
        // a: pushed, no PR → ready; b: green on a pushed parent → ready; s: green → ready
        #expect(a.rows == ["p:r:tree", "b:r:b", "p:r:solo", "b:r:s"])
    }

    @Test func pArmsThenSendsAndEscDisarms() {
        let a = world()
        a.setCursor("p:r:solo"); a.keys.handle("l"); a.keys.handle("j")
        #expect(a.selected == "b:r:s")
        #expect(BranchCommands.pushRoute("r:s", a) == "branch.push.arm")
        a.keys.handle("p")
        #expect(a.forestModel.armed == "r:s")
        #expect(BranchCommands.pushRoute("r:s", a) == "branch.push.confirm")
        a.keys.handle("esc")
        #expect(a.forestModel.armed == nil)
        #expect(a.registry.command("branch.push.confirm")!.available!("r:s") == false, "an unarmed confirm sends nothing")
        a.forestModel.armed = "r:s"
        let sent = try! a.registry.command("branch.push.confirm")!.write!("r:s", nil)!
        #expect(sent.path == "/push-origin" && sent.body == ["branch": "s", "stay": true])
        #expect(a.forestModel.armed == nil)
        // a branch with only the gates in the way: p runs them
        #expect(BranchCommands.pushRoute("r:c", a) == "branch.gates.run")
    }

    @Test func aRefusedForceKeepsTheScopeItsAnswerCarries() throws {
        let a = world()
        let ship = ShipState.of(a)
        ship.putForceScope(a, "r:s", ForceScope(eligible: true, guards: [], lease: "aaaaaaa", prNumber: nil, prUrl: nil))
        a.forestModel.armed = "r:s"
        let w = try #require(try a.registry.command("branch.force.confirm")!.write!("r:s", nil))
        #expect(w.path == "/force-origin" && w.body == ["branch": "s", "lease": "aaaaaaa"])
        w.answered?(false, ["forceScope": ["eligible": false, "guards": [["k": "pr", "label": "PR merged", "ok": false]], "lease": "bbbbbbb"]])
        #expect(ship.forceScopeOf(a, "r:s") == .some(ForceScope(eligible: false, guards: [.init(k: "pr", label: "PR merged", ok: false)], lease: "bbbbbbb", prNumber: nil, prUrl: nil)))
    }

    @Test func projectMovesAreOneWriteEachWithAnUndo() throws {
        let a = world()
        let w = try a.registry.command("project.archive")!.write!("r:bench", nil)!
        #expect(w.path == "/project-state" && w.body == ["repo": "r", "project": "bench", "state": "archive"])
        #expect(w.ops.first?.fields["state"] == "archive" && w.ops.first?.fields["rank"] == .null)
        #expect(w.inverse?([:])?.id == "project.workbench")
        let f = try a.registry.command("project.focus")!.write!("r:bench", nil)!
        #expect(f.ops.first?.fields["rank"] == 3)
        #expect(a.registry.command("project.focus")!.keys == [", f"], "focus is the page's own: under the leader")
    }

    @Test func cjAndCkReorderTheFocusLane() throws {
        let a = world()
        let w = try a.registry.command("focus.down")!.write!("r:tree", nil)!
        #expect(w.path == "/focus")
        #expect(w.body == ["order": [["repo": "r", "project": "solo"], ["repo": "r", "project": "tree"]]])
        #expect(w.inverse?([:])?.id == "focus.move" && w.inverse?([:])?.arg as? Int == 0)
        #expect(try a.registry.command("focus.up")!.write!("r:tree", nil) == nil, "already first")
    }

    @Test func aHoldCoversTheRowsUnopenedBranches() throws {
        let a = world()
        let w = try a.registry.command("hold.morning")!.write!("p:r:tree", nil)!
        #expect(w.path == "/outbox-hold")
        // a has a PR, so the hold covers b, c, d
        #expect(w.body["branches"] == ["b", "c", "d"])
        #expect(w.body["until"] == "2026-10-23T16:00:00.000Z", "Thursday 11am PT holds for Friday 9am")
        #expect(w.inverse?([:])?.id == "hold.release")
    }

    @Test func launchOpensTheSpineAtTheFirstUnopenedBranch() {
        let a = world()
        a.keys.handle(","); a.keys.handle("l")
        #expect(a.forestModel.launching == "r:tree" && a.selected == "b:r:b")
        a.keys.handle("esc")
        #expect(a.forestModel.launching == nil)
    }
}

/// What the views would report on screen: every row of the focused pane, stacked.
@MainActor
private func showRows(_ a: AppModel) {
    for (i, r) in a.rows.enumerated() { a.noteTarget(LabelTarget(pane: "main", key: r, rect: CGRect(x: 40, y: 100 + i * 40, width: 600, height: 32), title: "")) }
}

@MainActor @Suite(.serialized) struct ForestPageNavTests {
    func page() -> AppModel { world(.forest(repo: "r", project: "tree")) }

    @Test func jAndKWalkMergeOrderAndRecordJumps() {
        let a = page()
        #expect(a.rows == ["b:r:a", "b:r:b", "b:r:c", "b:r:d"])
        a.keys.handle("J")
        #expect(a.selected == "b:r:b")
        a.keys.handle("J"); a.keys.handle("J")
        #expect(a.selected == "b:r:d")
        a.keys.handle("J")
        #expect(a.selected == "b:r:d", "the last stays put")
        a.keys.handle("K")
        #expect(a.selected == "b:r:c")
        for id in ["forest.branch.next", "forest.branch.prev", "forest.parent", "forest.child", "forest.root", "forest.tip", "forest.next.ready"] {
            #expect(a.registry.command(id)?.recordsJump == true, "\(id)")
        }
        #expect(a.jumps.back.count >= 4, "each J/K left a jumplist entry")
    }

    @Test func gkAndGjWalkTheDAGWithLabelsAtAFork() {
        let a = page()
        a.setCursor("b:r:d")
        a.keys.handle("g"); a.keys.handle("k")
        #expect(a.selected == "b:r:c")
        a.keys.handle("g"); a.keys.handle("k")
        #expect(a.selected == "b:r:a")
        a.runner.dispatch("forest.parent", via: .palette)
        #expect(a.selected == "b:r:a" && a.runner.note?.contains("sits on main") == true, "\(a.runner.note ?? "")")
        // a forks into b and c: g j asks which, through the label layer over just the children
        showRows(a)
        a.keys.handle("g"); a.keys.handle("j")
        #expect(a.keys.layer == .labels)
        #expect(a.labeling?.items.map(\.key) == ["b:r:b", "b:r:c"])
        #expect(a.forestModel.childChoice == nil, "the restriction lasts one layer")
        let c = a.labeling!.label("main", "b:r:c")!
        for k in c { a.keys.handle(String(k)) }
        #expect(a.keys.layer == nil && a.selected == "b:r:c" && a.router.route == .forest(repo: "r", project: "tree"), "a pick only moves the cursor")
        a.setCursor("b:r:c")
        a.keys.handle("g"); a.keys.handle("j")
        #expect(a.selected == "b:r:d", "one child: no question")
    }

    @Test func gShiftKAndGShiftJGoToRootAndTip() {
        let a = page()
        a.setCursor("b:r:d")
        a.keys.handle("g"); a.keys.handle("K")
        #expect(a.selected == "b:r:a")
        a.keys.handle("g"); a.keys.handle("J")
        #expect(a.selected == "b:r:d", "past the fork, the descendant that merges last")
    }

    @Test func ourOwnTargetsComeFromTheViewsAndFind() {
        let a = page()
        showRows(a)
        #expect(a.provider!.targets(a).map(\.key) == a.rows)
        #expect(a.provider!.title(for: "b:r:b", a) == "b b does it")
        a.keys.handle("space"); a.keys.handle("f")
        #expect(a.keys.layer == .picker)
        a.keys.handle("down"); a.keys.handle("down"); a.keys.handle("ret")
        #expect(a.selected == "b:r:c")
    }

    @Test func theJumplistKeepsTheFace() {
        let a = page()
        a.keys.handle("tab")
        var p = a.here()
        #expect(p.tab == "story")
        a.keys.handle("tab")
        p.cursorKey = "d:r:tree#9"
        a.provider!.restore(p, a)
        #expect(a.forestModel.face == .story && a.selected == "d:r:tree#9")
    }

    @Test func tabTurnsToTheStoryAndEOpensAChaptersWhy() {
        let a = page()
        a.keys.handle("tab")
        #expect(a.forestModel.face == .story)
        // landed first, then in flight (a has a PR), then what's left
        #expect(a.rows == ["d:r:tree#9", "b:r:a", "b:r:b", "b:r:c", "b:r:d"])
        #expect(a.selected == "d:r:tree#9")
        a.keys.handle("e")
        #expect(a.forestModel.wordsOpen.contains("d:r:tree#9"))
        a.keys.handle("j"); a.keys.handle("e")
        #expect(a.forestModel.wordsOpen.contains("r:a"))
        a.keys.handle("tab")
        #expect(a.forestModel.face == .branches)
    }

    @Test func iDescribesInPlaceAndEscLeavesIt() {
        let a = page()
        a.keys.handle("i")
        #expect(a.keys.mode == .insert && a.insertField == BranchCommands.describeField && a.forestModel.describing == "r:a")
        #expect(a.forestModel.draft == "a does it")
        #expect(!a.keys.handle("j"), "typing goes to the field")
        a.forestModel.draft = "  a   does  more "
        a.keys.handle("ret")
        #expect(a.keys.mode == .normal && a.forestModel.describing == nil)
        #expect(a.store.view(Branch.self, "r:a")?.description == "a does more", "shown at once, one line")
        let w = try! a.registry.command("branch.describe")!.write!("r:a", "a does it")
        #expect(w == nil || w?.body["description"] == "a does it")
    }

    @Test func integrationWithNoServerIsFailedNotConflicts() async {
        let a = page()
        await a.forestModel.checkIntegration("r:tree")
        #expect(a.forestModel.verdict("r:tree")?.state == .failed)
        #expect(!a.forestModel.integratable("r:solo"), "a one-branch forest is its own integration")
    }
}

/// structure.test.ts for this folder: writes go through commands, never straight to the server;
/// telemetry comes from the runner and router; keys come only through the modal engine.
@Suite struct ForestsStructureTests {
    @Test func theFolderKeepsTheChokePoints() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Sources/CanopyUI/Pages/Forests").standardized
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).filter { $0.pathExtension == "swift" }
        #expect(files.count > 5)
        let banned = ["transport.post(", "URLSession", "telemetry.emit(", "telemetry.count(", "NSEvent", ".onKeyPress", ".keyboardShortcut", "onSubmit"]
        for f in files {
            let text = try String(contentsOf: f, encoding: .utf8)
            for b in banned { #expect(!text.contains(b), "\(f.lastPathComponent) uses \(b)") }
        }
    }
}
