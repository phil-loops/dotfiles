import CanopyCore
import Foundation
import Testing
@testable import CanopyUI

/// The Ship area's pure rules, ported case for case from v2's gates.test.ts, syncing.test.ts,
/// outlineHints.test.ts and the markdown half of review.test.ts.
@Suite struct GatesRunTests {
    let plan = GateEvent(event: "plan", planned: ["env", "typecheck", "tests"])
    func line(_ rows: [GateRow]) -> [String] { rows.map { "\($0.name):\($0.state.rawValue):\($0.ms.map { String(Int($0)) } ?? "null")" } }

    @Test func aRunInFlight() {
        let rows = GatesRun.rows(GateProgress(running: true, events: [plan, GateEvent(event: "done", gate: "env", ok: true, ms: 900), GateEvent(event: "start", gate: "typecheck", ts: 100)]), now: 130)
        #expect(line(rows) == ["env:green:900", "typecheck:running:30000", "tests:queued:null"])
    }

    @Test func aRunWithNoGateRunningSaysWhatItsWaitingOn() {
        #expect(GatesRun.between([], inFlight: true) == "gates starting")
        let queued = GatesRun.rows(GateProgress(running: true, events: [plan]), now: 0)
        #expect(GatesRun.between(queued, inFlight: true) == "gates starting")
        let gap = GatesRun.rows(GateProgress(running: true, events: [plan, GateEvent(event: "done", gate: "env", ok: true, ms: 900)]), now: 0)
        #expect(GatesRun.between(gap, inFlight: true) == "typecheck next")
        let busy = GatesRun.rows(GateProgress(running: true, events: [plan, GateEvent(event: "start", gate: "env", ts: 0)]), now: 1)
        #expect(GatesRun.between(busy, inFlight: true) == nil)
        #expect(GatesRun.between([], inFlight: false) == nil)
    }

    @Test func aRunningGateQuietPastTheThresholdReadsAsStuck() {
        let live = GateProgress(running: true, events: [plan, GateEvent(event: "done", gate: "env", ok: true, ms: 100), GateEvent(event: "start", gate: "typecheck", ts: 0)],
                                tail: GateProgress.Tail(gate: "typecheck", lines: ["…"], age: 40))
        #expect(GatesRun.stuck(GatesRun.rows(live, now: 100)) == nil)   // 40 s quiet is a slow typecheck
        let quiet = GateProgress(running: true, events: live.events, tail: GateProgress.Tail(gate: "typecheck", lines: ["…"], age: 900))
        #expect(GatesRun.stuck(GatesRun.rows(quiet, now: 1000))?.name == "typecheck")
        let finished = GateProgress(running: false, events: live.events, tail: GateProgress.Tail(gate: "typecheck", lines: ["…"], age: 900))
        #expect(GatesRun.stuck(GatesRun.rows(finished, now: 1000)) == nil, "a finished run is never stuck")
    }

    @Test func outputShowsInFullOnlyOnRequestOrOnARedGate() {
        let rows = [GateRow(name: "lint", state: .running, ms: 10000), GateRow(name: "tests", state: .red, ms: 900), GateRow(name: "env", state: .green, ms: 100)]
        #expect(GatesRun.fullOutput("lint", rows: rows, shown: nil) == false)   // running: a count until asked
        #expect(GatesRun.fullOutput("lint", rows: rows, shown: "lint") == true)
        #expect(GatesRun.fullOutput("tests", rows: rows, shown: nil) == true)   // red: always
        #expect(GatesRun.fullOutput("env", rows: rows, shown: nil) == false)
    }

    @Test func aFinishedRunLendsNoTimeToAnOptimisticRunning() {
        // Phil's p raced a run that finished the same second: the overlay says running, the
        // server's last answer is the finished run — its elapsed must not stand on the chip
        let finished = GateProgress(running: false, elapsed: 1239, events: [plan, GateEvent(event: "done", gate: "env", ok: true, ms: 900),
                                                                           GateEvent(event: "done", gate: "typecheck", ok: true, ms: 900), GateEvent(event: "done", gate: "tests", ok: true, ms: 900)])
        let w = GatesRun.waiting(finished, rows: GatesRun.rows(finished, now: 1239), inFlight: true, now: 1239)
        #expect(w?.text == "gates starting" && w?.secs == nil)
        let live = GateProgress(running: true, elapsed: 3, events: [])
        #expect(GatesRun.waiting(live, rows: [], inFlight: true, now: 3)?.secs == 3)
    }

    @Test func aRunInSetupNamesTheStepAndTurnsStuckAfterFiveMinutes() {
        let queued = GateProgress(running: true, elapsed: 4452, events: [
            GateEvent(event: "queued", ts: 0),
            GateEvent(event: "setup", ts: 10, step: "queue", position: 2, behind: "move-notices-out-of-the-feed")])
        let w = GatesRun.waiting(queued, rows: GatesRun.rows(queued, now: 70), inFlight: true, now: 70)
        #expect(w?.text == "#2 in line for gates · move-notices-out-of-the-feed running · p puts it next" && w?.secs == 60 && w?.stuck == false)
        let checkout = GateProgress(running: true, elapsed: 4452, events: [GateEvent(event: "setup", ts: 0, step: "checkout")])
        let s = GatesRun.waiting(checkout, rows: GatesRun.rows(checkout, now: 4452), inFlight: true, now: 4452)
        #expect(s?.text == "stuck preparing the checkout" && s?.stuck == true)
        let agentsAhead = GateProgress(running: true, events: [GateEvent(event: "setup", ts: 0, step: "queue", position: 9, behind: "adopt-legacy-disables",
                                                                         ahead: ["interactive": 0, "ship": 3, "background": 5], tier: "background")])
        #expect(GatesRun.waiting(agentsAhead, rows: [], inFlight: true, now: 1)?.text == "#9 in line · behind 3 ready to ship, 5 agent · p puts it next")
        let clicked = GateProgress(running: true, events: [GateEvent(event: "setup", ts: 0, step: "queue", position: 2, behind: "a",
                                                                     ahead: ["interactive": 1, "ship": 0, "background": 0], tier: "interactive")])
        #expect(GatesRun.waiting(clicked, rows: [], inFlight: true, now: 1)?.text == "#2 in line · behind 1 yours · p puts it next")
        let next = GateProgress(running: true, events: [GateEvent(event: "setup", ts: 0, step: "queue", position: 1, behind: "stack-donor")])
        #expect(GatesRun.waiting(next, rows: [], inFlight: true, now: 1)?.text == "waiting on stack-donor")
        let planned = GateProgress(running: true, elapsed: 3, events: [GateEvent(event: "setup", ts: 0, step: "env"), plan])
        #expect(GatesRun.setup(planned) == nil)
    }

    @Test func aQuickRunNamesTheGatesItLeftToCI() {
        let rows = GatesRun.rows(GateProgress(running: false, events: [plan,
            GateEvent(event: "done", gate: "env", ok: true, ms: 900),
            GateEvent(event: "done", gate: "typecheck", ok: true, ms: 0, warn: "typecheck skipped (quick gates — CI checks it)"),
            GateEvent(event: "done", gate: "tests", ok: true, ms: 0, warn: "tests skipped by you")]), now: 0)
        #expect(GatesRun.quick(rows) == ["typecheck"])
        #expect(rows.filter { $0.state == .waived }.count == 2)
    }

    @Test func aRunThatDiedMidGateSaysStopped() {
        let rows = GatesRun.rows(GateProgress(running: false, events: [plan, GateEvent(event: "start", gate: "env", ts: 1)], dead: true), now: 500)
        #expect(rows.map(\.state) == [.stopped, .stopped, .stopped])
    }

    @Test func aFinishedRunCarriesEachGatesSummary() {
        let rows = GatesRun.rows(GateProgress(running: false, events: [
            plan, GateEvent(event: "done", gate: "env", ok: true, ms: 5), GateEvent(event: "done", gate: "typecheck", ok: false, ms: 6),
            GateEvent(event: "done", gate: "tests", ok: true, ms: 7),
            GateEvent(event: "result", verdicts: [.init(name: "typecheck", ok: false, ms: 6, summary: "3 errors")], ok: false),
        ]), now: 0)
        #expect(rows.map { "\($0.name):\($0.state.rawValue)" } == ["env:green", "typecheck:red", "tests:green"])
        #expect(rows[1].summary == "3 errors")
    }

    @Test func aWaivedGateReadsAsWaived() {
        let rows = GatesRun.rows(GateProgress(running: false, events: [GateEvent(event: "plan", planned: ["tests"]), GateEvent(event: "done", gate: "tests", ok: true, ms: 0, warn: "tests skipped by you")]), now: 0)
        #expect(rows == [GateRow(name: "tests", state: .waived, ms: 0, summary: "tests skipped by you")])
    }

    @Test func decodesTheJournal() throws {
        let json = #"{"running":true,"elapsed":12.5,"events":[{"event":"plan","gates":["env","tests"]},{"event":"start","gate":"env","ts":10},{"event":"result","ok":true,"gates":[{"name":"env","ok":true,"ms":3}]}],"tail":{"gate":"env","lines":["ok"]}}"#
        let p = try JSONDecoder().decode(GateProgress.self, from: Data(json.utf8))
        #expect(p.events?.first?.planned == ["env", "tests"])
        #expect(p.events?.last?.verdicts?.first?.name == "env")
        #expect(p.tail?.lines == ["ok"])
    }

    @Test func environmentFailureSkipsTheGatesThatNeverStarted() throws {
        let json = #"{"running":false,"events":[{"event":"plan","gates":["env","typecheck","tests"]},{"event":"done","gate":"env","ok":false,"ms":42},{"event":"result","ok":false,"note":"environment not ready — tests skipped; re-run","gates":[{"name":"env","ok":false,"ms":42,"summary":"Postgres is down"}]}]}"#
        let p = try JSONDecoder().decode(GateProgress.self, from: Data(json.utf8))
        let rows = GatesRun.rows(p, now: 100)
        #expect(rows.map(\.state) == [.red, .skipped, .skipped])
        #expect(rows[0].summary == "Postgres is down")
        #expect(rows[1].summary == "environment not ready — tests skipped; re-run")
        #expect(rows.dropFirst().allSatisfy { $0.ms == nil })
        #expect(GatesStrip.step[.skipped] == .skip && rows[1].label == "typecheck skipped")
    }

    @Test func checkoutFailureNeedsNoDoneEvent() throws {
        let json = #"{"running":false,"events":[{"event":"plan","gates":["worktree"]},{"event":"result","ok":false,"gates":[{"name":"worktree","ok":false,"ms":0,"summary":"checkout is dirty"}]}]}"#
        let p = try JSONDecoder().decode(GateProgress.self, from: Data(json.utf8))
        #expect(GatesRun.rows(p, now: 100) == [GateRow(name: "worktree", state: .red, ms: 0, summary: "checkout is dirty")])
    }

    @Test func terminalQueueFailureNeedsNoPlanAndEndsSetup() throws {
        let json = #"{"running":true,"elapsed":1000,"events":[{"event":"setup","step":"queue","ts":1},{"event":"result","ok":false,"gates":[{"name":"queue","ok":false,"summary":"branch changed while queued — re-run"}]}]}"#
        let p = try JSONDecoder().decode(GateProgress.self, from: Data(json.utf8))
        let rows = GatesRun.rows(p, now: 1000)
        #expect(rows == [GateRow(name: "queue", state: .red, ms: nil, summary: "branch changed while queued — re-run")])
        #expect(!GatesRun.isRunning(p) && GatesRun.setup(p) == nil)
        #expect(GatesRun.waiting(p, rows: rows, inFlight: true, now: 1000) == nil)
    }

    @Test func terminalVerdictsPreserveWaiversAndSupersedeTransientEvents() throws {
        let json = #"{"running":true,"events":[{"event":"plan","gates":["env","typecheck","tests"]},{"event":"done","gate":"env","ok":true,"ms":1},{"event":"start","gate":"typecheck","ts":1},{"event":"result","ok":false,"gates":[{"name":"env","ok":false,"ms":2,"summary":"final failure"},{"name":"typecheck","ok":true,"ms":0,"skipped":true,"advisory":true,"warn":"typecheck skipped (quick gates — CI checks it)"},{"name":"tests","ok":true,"ms":0,"warn":"tests skipped by you"}]}]}"#
        let p = try JSONDecoder().decode(GateProgress.self, from: Data(json.utf8))
        let rows = GatesRun.rows(p, now: 100)
        #expect(rows.map(\.state) == [.red, .waived, .waived])
        #expect(rows[0].ms == 2 && rows[0].summary == "final failure")
        #expect(GatesRun.quick(rows) == ["typecheck"])
        #expect(rows[2].summary == "tests skipped by you")
        #expect(GatesRun.waiting(p, rows: rows, inFlight: true, now: 100) == nil)
    }

    @Test func aStartedGateWithoutAVerdictStopsAtTheTerminalTime() throws {
        let json = #"{"running":true,"events":[{"event":"plan","gates":["env","tests","lint"]},{"event":"start","gate":"tests","ts":10},{"event":"result","ts":12,"ok":false,"gates":[{"name":"env","ok":false}]}],"tail":{"gate":"tests","lines":[],"age":999}}"#
        let p = try JSONDecoder().decode(GateProgress.self, from: Data(json.utf8))
        let rows = GatesRun.rows(p, now: 100)
        #expect(rows.map(\.state) == [.red, .stopped, .skipped])
        #expect(rows[1].ms == 2000 && rows[1].quiet == nil)
        #expect(GatesRun.rows(p, now: 200) == rows)
        #expect(GatesRun.stuck(rows) == nil)
    }

    @Test func obsoleteRunsKeepCompletedGatesAndStopOnlyTheStartedGate() throws {
        let json = #"{"running":true,"events":[{"event":"plan","gates":["env","tests","lint"]},{"event":"done","gate":"env","ok":true,"ms":30},{"event":"start","gate":"tests","ts":10},{"event":"result","ok":false,"gates":[{"name":"queue","ok":false,"summary":"branch changed while running — re-run"}]}]}"#
        let p = try JSONDecoder().decode(GateProgress.self, from: Data(json.utf8))
        let rows = GatesRun.rows(p, now: 100)
        #expect(rows.map(\.name) == ["env", "tests", "lint", "queue"])
        #expect(rows.map(\.state) == [.green, .stopped, .skipped, .red])
        #expect(rows[1].ms == nil && rows[1].label == "tests stopped" && GatesStrip.step[.stopped] == .idle)
        #expect(GatesRun.rows(p, now: 200) == rows)
    }

    @Test func anEmptyTerminalResultEndsAllWaiting() throws {
        let json = #"{"running":true,"elapsed":1000,"events":[{"event":"setup","step":"env","ts":1},{"event":"result","ok":true,"note":"no gates configured for this repo","gates":[]}]}"#
        let p = try JSONDecoder().decode(GateProgress.self, from: Data(json.utf8))
        #expect(!GatesRun.isRunning(p) && GatesRun.setup(p) == nil)
        #expect(GatesRun.waiting(p, rows: [], inFlight: true, now: 1000) == nil)
    }

    @Test func aDeadSetupCannotBorrowAnOptimisticRunningState() throws {
        let json = #"{"running":false,"dead":true,"elapsed":999,"events":[{"event":"setup","step":"queue","ts":1,"behind":"other-branch"}]}"#
        let p = try JSONDecoder().decode(GateProgress.self, from: Data(json.utf8))
        let rows = GatesRun.rows(p, now: 1000)
        #expect(rows == [GateRow(name: "queue", state: .stopped, ms: nil)])
        #expect(!GatesRun.isRunning(p))
        #expect(GatesRun.waiting(p, rows: rows, inFlight: true, now: 1000) == nil)
    }

    @Test func secs() {
        #expect(GatesRun.secs(nil) == "")
        #expect(GatesRun.secs(4400) == "4s")
        #expect(GatesRun.secs(125_000) == "2m 5s")
    }
}

func shipBranch(_ f: (inout Branch) -> Void = { _ in }) -> Branch {
    let json: JSONValue = ["id": "r:f/b", "repo": "r", "name": "f/b", "project": "r:f", "parent": "f/a", "parentId": "r:f/a", "description": "",
                           "subject": "s", "commits": 1, "outline": ["s"], "tip": "t", "tree": "x", "pushed": "local", "ahead": 0, "gates": "none",
                           "redGates": [], "order": 1, "holdUntil": nil, "behind": 0, "drifted": false, "upstream": "", "upstreamBad": false, "diverged": false]
    var b = try! json.decode(Branch.self)
    f(&b)
    return b
}

@Suite struct SyncingTests {
    @Test func aBranchAtRestNeedsNoSync() {
        #expect(Syncing.needs(shipBranch(), facts: SyncFacts(), prep: PrepRoute(route: "ready")) == [])
        #expect(Syncing.needs(shipBranch(), facts: SyncFacts(), prep: PrepRoute(route: "nothing")) == [])
    }

    @Test func dirtDriftLagAndAnUnvoicedTailEachMakeItNeedOne() {
        #expect(Syncing.needs(shipBranch(), facts: SyncFacts(dirty: ["a.ts", "b.ts"])) == ["2 uncommitted"])
        #expect(Syncing.needs(shipBranch { $0.drifted = true }) == ["off f/a's tip"])
        // its own parent is current but a branch above it moved: the chain owes a catch-up
        #expect(Syncing.needs(shipBranch { $0.owes = "f/up" }) == [], "p catches the chain up: one remedy")
        #expect(Syncing.needs(shipBranch(), facts: SyncFacts(behind: 3, restack: true)) == ["3 behind main"])
        #expect(Syncing.needs(shipBranch(), prep: PrepRoute(route: "squash")) == ["not one voiced commit"])
        #expect(Syncing.needs(shipBranch(), prep: PrepRoute(route: "additive")) == ["diverged from its PR"])
        // a GitHub-side rewrite with nothing local lacks is a conform, never "diverged"
        #expect(Syncing.needs(shipBranch { $0.diverged = true }, prep: PrepRoute(route: "conform")) == [], "p takes origin's copy: one remedy")
        #expect(Syncing.needs(shipBranch { $0.diverged = true }, prep: PrepRoute(route: "ready")) == ["diverged from origin"])
    }

    @Test func behindMainAloneIsntAReasonWhenNothingCouldRebaseIt() {
        #expect(Syncing.needs(shipBranch(), facts: SyncFacts(behind: 3, published: true)) == [])
    }

    @Test func theStepsFollowV1sOrder() {
        #expect(Syncing.planSteps(drifted: false, facts: SyncFacts()).map(\.id) == [.dirt, .prep, .gates, .tests])
        #expect(Syncing.planSteps(drifted: true, facts: SyncFacts(behind: 2, syncable: true)).map(\.id) == [.dirt, .reseat, .rebase, .prep, .gates, .tests])
        #expect(Syncing.planSteps(drifted: true, facts: SyncFacts())[1].label == "catch up")
        #expect(Syncing.planSteps(drifted: false, facts: SyncFacts(behind: 2, restack: true))[1].label == "restack")
    }

    @Test func aSyncAnswerReads() {
        #expect(Syncing.rebaseOf(true, ["rebased": true, "summary": "replayed 2 commits onto origin/main"]) == .rebased(note: "replayed 2 commits onto origin/main"))
        #expect(Syncing.rebaseOf(true, ["restack": true, "project": "f"]) == .restack(project: "f"))
        #expect(Syncing.rebaseOf(true, ["contract": true]) == .contract)
        #expect(Syncing.rebaseOf(true, ["ejected": true, "conflict": true, "stream": "rebase:f/b"]) == .conflict)
        if case .refused = Syncing.rebaseOf(false, ["err": "has an open PR"]) {} else { Issue.record("not refused") }
    }

    @Test func aPrepPushAnswer() {
        #expect(Syncing.prepOf(true, ["routed": ["sealed 3 unpushed commits into one (voiced)"]]) == .ok(note: "sealed 3 unpushed commits into one (voiced)"))
        if case .rest = Syncing.prepOf(false, ["err": "nothing to push — origin already has this"]) {} else { Issue.record("not rest") }
        if case .rest = Syncing.prepOf(false, ["vehiclePending": true, "err": "x"]) {} else { Issue.record("not rest") }
        if case .claude = Syncing.prepOf(false, ["reconcile": true, "err": "diverged from origin without an open PR"]) {} else { Issue.record("not claude") }
        #expect(Syncing.prepOf(false, ["err": "unpushed commits include a merge"]) == .fail(note: "unpushed commits include a merge"))
    }

    @Test func theTestsAreAdvice() {
        #expect(Syncing.testsOf(["ran": true, "ok": true, "passed": 4]).note == "4 ✓")
        #expect(Syncing.testsOf(["noTests": true]).note == "no changed tests")
        let red = Syncing.testsOf(["ran": true, "ok": false, "failed": 1, "summary": "✖ it breaks\nat line 3"])
        #expect(red.state == .fail)
        #expect(red.note.hasSuffix("it breaks\nat line 3"))
        #expect(Syncing.testsOf(["err": "network"]).note == "couldn't run")
    }

    /// A step that couldn't run is never drawn as done.
    @Test func testsThatCouldntRunAreNotATick() {
        #expect(Syncing.testsOf(["err": "network"]).state == .fail)
        let unrun = Syncing.testsOf(["ran": false, "summary": "no test database"])
        #expect(unrun.state == .fail && unrun.note == "no test database")
        #expect(Syncing.testsOf(["noTests": true]).state == .ok)
    }

    /// Starting the gates isn't passing them: the step reads the branch's live gates.
    @Test func theGatesStepIsTheBranchsGates() {
        #expect(Syncing.gatesShown(.run, live: .running) == .run)
        #expect(Syncing.gatesShown(.run, live: .stale) == .run)
        #expect(Syncing.gatesShown(.run, live: .green) == .ok)
        #expect(Syncing.gatesShown(.run, live: .red) == .fail)
        #expect(Syncing.gatesShown(.skip, live: .green) == .skip)
        #expect(Syncing.gatesShown(.idle, live: .red) == .idle)
    }

    @Test func onlyASealSendsYouToTheWords() {
        #expect(Syncing.sealed(["routed": ["sealed 3 unpushed commits into one (voiced)"]]))
        #expect(!Syncing.sealed(["routed": ["2 voiced commits — pushed as they are, no seal"]]))
        #expect(!Syncing.sealed([:]))
    }

    @Test func decodesALiveSyncRead() throws {
        // GET /loops/sync?branch=add-email-reading-format, 2026-10-29
        let json = #"{"branch": "add-email-reading-format", "behind": 81, "parent": "main", "published": false, "syncable": true, "restack": false, "project": "email-destinations", "shared": "local", "aheadOfOrigin": 0, "dirty": [], "dirtyRows": [], "dirtyWorktree": "", "deployCritical": [], "why": ""}"#
        let f = try JSONDecoder().decode(SyncFacts.self, from: Data(json.utf8))
        #expect(f.behind == 81 && f.syncable && Syncing.rebases(f))
        let p = try JSONDecoder().decode(PrepRoute.self, from: Data(#"{"ok": true, "branch": "x", "route": "restack", "why": "81 behind", "next": {"method": "POST", "path": "/sync", "body": {"branch": "x"}}}"#.utf8))
        #expect(p.route == "restack")
    }
}

@Suite struct OutlineHintsTests {
    func ids(_ h: [WordsHint]) -> [String] { h.map(\.id) }
    func w(_ s: String, _ b: String = "") -> MessageWords { MessageWords(subject: s, body: b) }

    @Test func prefixOfReadsTypeScopeAndBang() {
        #expect(OutlineHints.prefixOf("feat(LOO-1)!: add it") == .init(type: "feat", scope: "LOO-1", bang: "!", rest: "add it"))
        #expect(OutlineHints.prefixOf("complaints -> spamReports") == nil)
        #expect(OutlineHints.prefixOf("note: not a type") == nil)
    }

    @Test func withScopeNormalizes() {
        #expect(OutlineHints.withScope("feat(LOO-6222): find messages", "loo-6222") == "feat(loo-6222): find messages")
        #expect(OutlineHints.withScope("fix: stop flicker", "loo-1") == "fix(loo-1): stop flicker")
        #expect(OutlineHints.withScope("stop flicker", "loo-1") == "feat(loo-1): stop flicker")
    }

    @Test func aCleanOpeningCommitHasNoHints() {
        #expect(OutlineHints.hintsFor(w("feat(loo-9): add widget queries"), opening: true, ticket: "loo-9").isEmpty)
    }

    @Test func theOpeningCommitWantsTheTicketScopeLowercase() {
        let h = OutlineHints.hintsFor(w("feat(LOO-9): add widget queries"), opening: true, ticket: "loo-9")
        #expect(ids(h) == ["scope"])
        #expect(h[0].fix?.apply(w("feat(LOO-9): add widget queries")).subject == "feat(loo-9): add widget queries")
    }

    @Test func followUpsReadBare() {
        #expect(ids(OutlineHints.hintsFor(w("refactor: extract the widget card"), opening: false, ticket: "loo-9")) == ["bare"])
        #expect(OutlineHints.bare("refactor(x): extract the widget card") == "extract the widget card")
    }

    @Test func lengthIsTheWordsAfterThePrefix() {
        for s in ["feat(LOO-6208): Unlock goal window", "fix(loo-6120): render critical notice", "feat(loo-6219): drop legacy admin interaction stuff",
                  "fix(LOO-5990): Allowlist the campaign update body"] {
            let ticket = String(s[s.index(after: s.firstIndex(of: "(")!)..<s.firstIndex(of: ")")!])
            #expect(!ids(OutlineHints.hintsFor(w(s), opening: true, ticket: ticket)).contains("long"), "\(s)")
        }
        #expect(ids(OutlineHints.hintsFor(w("fix(loo-6229): migrate the disable domain function to always leave breadcrumbs"), opening: true, ticket: "loo-6229")).contains("long"))
    }

    @Test func longSubjectsAndPlaceholdersAreFlagged() {
        #expect(ids(OutlineHints.hintsFor(w("wip " + String(repeating: "x", count: 60)), opening: false)) == ["wip", "long"])
    }

    @Test func aBakedForestBlockIsDetectedAndStripped() {
        let body = "Part of a stack (demo):\n\n1. demo/queries — adds the widget queries  ← this branch\n2. demo/model — moves rules\n\nThe query layer stays thin."
        #expect(OutlineHints.hasPlan(body))
        #expect(OutlineHints.stripPlan(body) == "The query layer stays thin.")
        #expect(OutlineHints.stripPlan("why it matters\n\nPart of a stack, in merge order:\n  1. [this branch]\n  2. #123") == "why it matters")
        #expect(OutlineHints.stripPlan("prose\n-- forest --\nPart of x, 1 of 2.") == "prose")
        let wrapped = "the why\n\nPart of a stack, in merge order:\n  1. #11090\n  2. [this branch]\n3. disable a team's domains in a transaction that records\nan event for each one it turns off\n4. record a disable event wherever an admin or a health check disables a\nsingle domain\n\n---\nTraffic Cop"
        #expect(OutlineHints.stripPlan(wrapped) == "the why\n\n---\nTraffic Cop")
        #expect(ids(OutlineHints.hintsFor(w("feat(loo-9): add", body), opening: true, ticket: "loo-9")) == ["plan"])
    }

    @Test func thePRTitleFollowsTheOpeningRuleButIgnoresBodies() {
        #expect(ids(OutlineHints.hintsFor(w("show widgets", "Part of a stack"), opening: true, ticket: "loo-9", kind: .title)) == ["scope"])
    }

    @Test func aPRBodysHints() {
        let tpl = "---\n👮 Traffic Cop\n\n- [ ] tested"
        #expect(OutlineHints.bodyHints("👋 fare thee well\n\n" + tpl, template: tpl).isEmpty)
        #expect(ids(OutlineHints.bodyHints("why\n\nPart of a stack, in merge order:\n  1. #1\n\n" + tpl, template: tpl)) == ["plan"])
        #expect(ids(OutlineHints.bodyHints(String(repeating: "x", count: 300) + "\n\n" + tpl, template: tpl)) == ["prose"])
    }

    @Test func aPRBodySplitsIntoPhilsLinesAndTheTemplate() {
        let tpl = "---\n👮 Traffic Cop\n\n- [ ] Tested in staging"
        #expect(OutlineHints.splitTemplate("why it matters\n\n\(tpl)") == ("why it matters", tpl))
        #expect(OutlineHints.splitTemplate("\n\(tpl)") == ("", tpl))
        #expect(OutlineHints.splitTemplate("just a why") == ("just a why", ""))
        #expect(OutlineHints.joinTemplate("new why", tpl) == "new why\n\n\(tpl)")
        #expect(OutlineHints.joinTemplate("", tpl) == tpl)
        for typed in ["why ", "why\n", " ", "why\n\n"] { #expect(OutlineHints.splitTemplate(OutlineHints.joinTemplate(typed, tpl)).own == typed, "\(typed.debugDescription)") }
    }
}

@Suite struct MarkdownTests {
    @Test func nothingItDoesntRenderBecomesMarkup() {
        let blocks = Markdown.parse("<img src=x onerror=alert(1)> **b** [x](javascript:alert(1)) `<i>`")
        guard case .paragraph(let lines) = blocks.first else { Issue.record("no paragraph"); return }
        let spans = lines[0]
        #expect(spans.first?.text.hasPrefix("<img src=x") == true)
        #expect(spans.contains { $0.bold && $0.text == "b" })
        #expect(!spans.contains { $0.link != nil })
        #expect(spans.contains { $0.code && $0.text == "<i>" })
    }

    @Test func linksAreOnlyHttpAndKeepTheirURL() {
        let s = Markdown.inline("see [the PR](https://github.com/x/y/pull/1) and https://example.com/a.")
        #expect(s.first { $0.text == "the PR" }?.link == "https://github.com/x/y/pull/1")
        #expect(s.first { $0.text == "https://example.com/a" }?.link == "https://example.com/a")
        #expect(s.last?.text == ".")
        let evil = Markdown.inline("[a](https://x.test/\"onmouseover=\"alert(1))")
        #expect(evil.allSatisfy { $0.link == nil || !$0.link!.contains(" ") })
    }

    @Test func inlineStyles() {
        let s = Markdown.inline("a *it* _em_ ~~gone~~ @phil `x`")
        #expect(s.contains { $0.italic && $0.text == "it" })
        #expect(s.contains { $0.italic && $0.text == "em" })
        #expect(s.contains { $0.strike && $0.text == "gone" })
        #expect(s.contains { $0.mention && $0.text == "@phil" })
        #expect(s.contains { $0.code && $0.text == "x" })
        #expect(Markdown.inline("snake_case_name").count == 1)
    }

    @Test func aSuggestionRendersOverTheLinesItReplaces() {
        let b = Markdown.parse("Try:\n\n```suggestion\nconst x = 1;\n```", replaces: ["let x = 1;"])
        #expect(b.last == .suggestion(removes: ["let x = 1;"], adds: ["const x = 1;"]))
    }

    @Test func suggestionOfReadsTheBlock() {
        #expect(Markdown.suggestionOf("x\n```suggestion\na\n  b\n```") == ["a", "  b"])
        #expect(Markdown.suggestionOf("```suggestion\n```") == [])
        #expect(Markdown.suggestionOf("```ts\na\n```") == nil)
    }

    @Test func listsQuotesAndTemplateComments() {
        let b = Markdown.parse("<!-- hidden -->\n- [x] done\n- open\n\n> quoted")
        #expect(!Markdown.text(b).contains("hidden"))
        #expect(Markdown.text(b).contains("☑ done"))
        guard case .list(false, _, let items) = b.first else { Issue.record("no list"); return }
        #expect(items.count == 2 && items[0].task == true && items[1].task == nil)
        guard case .quote(let q) = b.last else { Issue.record("no quote"); return }
        #expect(Markdown.text(q) == "quoted")
    }

    @Test func blocks() {
        let b = Markdown.parse("# Title\n\npara one\nline two\n\n---\n\n| a | b |\n|---|---|\n| 1 | `x|y` |\n\n3. three\n4. four\n   - nested\n\n```ts\nlet x\n```")
        #expect(b.count == 6)
        #expect(b[0] == .heading(level: 1, [MdSpan("Title")]))
        if case .paragraph(let ls) = b[1] { #expect(ls.count == 2) } else { Issue.record("no paragraph") }
        #expect(b[2] == .rule)
        if case .table(let h, let rows) = b[3] { #expect(h.count == 2 && rows[0][1] == [MdSpan("x|y", code: true)]) } else { Issue.record("no table") }
        if case .list(true, 3, let items) = b[4] { #expect(items.count == 2 && !items[1].children.isEmpty) } else { Issue.record("no ordered list") }
        #expect(b[5] == .code(lang: "ts", lines: ["let x"]))
    }

    @Test func botHtmlBecomesMarkdown() {
        let b = Markdown.parse("<p>Linked to <a href=\"https://linear.app/x\">LOO-1</a></p><p>second</p>")
        #expect(b.count == 2)
        if case .paragraph(let ls) = b[0] { #expect(ls[0].contains { $0.link == "https://linear.app/x" && $0.text == "LOO-1" }) }
    }

    @Test func plainFoldsMarkdownToOneLine() {
        #expect(Markdown.plain("**Bold** `code`\n\n```suggestion\nx\n```\nmore") == "Bold code more")
        #expect(Markdown.plain(String(repeating: "a", count: 200), max: 10) == "aaaaaaaaa…")
    }
}
