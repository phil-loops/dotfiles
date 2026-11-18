import CanopyCore
import Foundation
import Testing
@testable import CanopyUI

@Suite struct WorkContextTests {
    static func body(_ text: String = "Keep the latest direction visible.", at: String = "2026-11-17T18:00:00Z", source: String = "chat", notes: String = "## Next steps\n\nBuild the context view.") -> String {
        "## Your input\n\n\(at) · \(source)\n\n" + text.components(separatedBy: "\n").map { "> \($0)" }.joined(separator: "\n") + "\n\n\(notes)"
    }

    @Test func inputRetainsVerbatimWordsAndSeparatesAgentNotes() throws {
        let text = "  please keep it moving\n\n## this is still my quote\n> quoted within it"
        let input = try #require(RecordedWorkInput.read(Self.body(text)))
        #expect(input.text == text && input.source == .chat)
        #expect(input.notes == "## Next steps\n\nBuild the context view.")
        #expect(input.when == "Nov 17, 2026 18:00 UTC")
    }

    @Test(arguments: ["chat", "review"]) func inputsKeepTheirExplicitSource(_ source: String) throws {
        #expect(try #require(RecordedWorkInput.read(Self.body(source: source))).source.rawValue == source)
    }

    @Test func proseAndProgressCannotBecomeYourInput() {
        for body in ["Phil said keep moving", "## Next steps\n\nKeep moving", "```markdown\n" + Self.body() + "\n```", "## Done\n\n" + Self.body()] {
            #expect(RecordedWorkInput.read(body) == nil)
        }
    }

    @Test func malformedAttributionStaysOrdinaryNotes() {
        let bodies = [Self.body(at: "yesterday"), Self.body(source: "claude"), Self.body("  \n "),
                      Self.body().replacingOccurrences(of: "> Keep", with: "Keep"),
                      Self.body().replacingOccurrences(of: "\n\n## Next steps", with: "\nnot quoted\n\n## Next steps"),
                      Self.body().replacingOccurrences(of: "18:00:00Z · chat", with: "18:00:00Z · chat · guessed")]
        for body in bodies { #expect(RecordedWorkInput.read(body) == nil) }
    }

    @Test func scopesKeepRepositoryForestAndFullBranchIdentity() {
        let items = [TodoItem(id: "viewer"),
            TodoItem(id: "a", project: "r:forest", solved_by: "feature/a"),
            TodoItem(id: "b", project: "r:forest", solved_by: "feature/ab"),
            TodoItem(id: "c", project: "other:forest", solved_by: "feature/a"),
            TodoItem(id: "unbound", project: "r:forest")]
        #expect(WorkContext(items, subject: .viewer).items.map(\.id) == ["viewer"])
        #expect(WorkContext(items, subject: .forest("r:forest")).items.map(\.id) == ["a", "b", "unbound"])
        #expect(WorkContext(items, subject: .branch(project: "r:forest", name: "feature/a")).items.map(\.id) == ["a"])
    }

    @Test func agentUpdatesDoNotReplaceTheLatestInput() throws {
        let old = TodoItem(id: "old", updated: "2026-11-20", body: Self.body("Earlier direction", at: "2026-11-16T18:00:00Z"))
        let new = TodoItem(id: "new", state: .done, updated: "2026-11-17", body: Self.body("Latest direction"))
        let notes = TodoItem(id: "notes", updated: "2026-11-21", body: "Agent summary of what Phil wants")
        let review = TodoItem(id: "review", body: Self.body("A newer review note", at: "2026-11-22T18:00:00Z", source: "review"))
        let context = WorkContext([old, new, notes, review], subject: .viewer)
        #expect(context.updated == "2026-11-21")
        let input = try #require(context.latestInput)
        #expect(input.item.id == "new" && input.input.text == "Latest direction")
        #expect(WorkContext([notes], subject: .viewer).latestInput == nil)
        #expect(RecordedWorkInput.chat(in: review.body) == nil)
        #expect(WorkContext([review], subject: .viewer).latestInput == nil)
    }

    @Test func dateOnlyUpdatesKeepTheirRecordedPrecision() {
        #expect(WorkContext.day("2024-02-29") == "2024-02-29")
        for value in ["2026-02-29", "2026-11-31", "2026-1-17", "2026-11-17T18:00:00Z", "yesterday", ""] {
            #expect(WorkContext.day(value) == nil)
        }
        let item = TodoItem(id: "new", created: "2026-11-17")
        #expect(WorkContext([item], subject: .viewer).updated == nil)
        #expect(WorkContext.updateLabel(nil) == "update date not recorded")
        #expect(WorkContext.updateLabel("2026-11-17") == "tracker updated 2026-11-17")
    }

    @Test func assignmentsAndStatusesDoNotClaimProcessLiveness() {
        let context = WorkContext([TodoItem(id: "busy", state: .doing), TodoItem(id: "waiting", state: .waiting),
                                   TodoItem(id: "call", kind: "decide"), TodoItem(id: "broken", kind: "decide", state: .broken),
                                   TodoItem(id: "done", state: .done)], subject: .viewer)
        #expect(context.summary == "1 in progress · 1 need you · 1 waiting")
        #expect(context.doing.map(\.id) == ["busy"])
        #expect(WorkContext.status(context.doing[0]) == "marked in progress")
        #expect(WorkContext.status(TodoItem(id: "future", state: "future")) == "state: future")
    }
}

@MainActor @Suite(.serialized) struct WorkContextNavigationTests {
    func item(_ title: String, state: String = "doing", project: String? = nil) -> [String: Any] {
        var item: [String: Any] = ["title": title, "kind": "build", "state": state, "area": "review", "size": "M", "why": "Make work visible", "updated": "2026-11-17", "owner": "session-a", "body": WorkContextTests.body()]
        if let project { item["project"] = project }
        return item
    }

    func app() -> AppModel {
        var local = item("Visible viewer work"); local["id"] = "viewer"
        var forest = item("Visible forest work", project: "r:tree"); forest["id"] = "forest"
        var closed = item("Closed", state: "done"); closed["id"] = "closed"
        return world(todo: ["viewer": local, "forest": forest, "closed": closed])
    }

    @Test func homeKeepsItsMainCursorAndAddsARealWorkPane() {
        let app = app()
        #expect(app.pane?.id == "main")
        #expect(app.panes.map(\.id) == ["main", "work"])
        #expect(app.panes.last?.rows == ["t:forest", "t:viewer"])
        app.keys.handle("C-w"); app.keys.handle("k")
        #expect(app.pane?.id == "work" && app.selected == "t:forest")
        app.keys.handle("j")
        #expect(app.selected == "t:viewer")
        app.keys.handle("ret")
        #expect(app.router.route == .todo)
        #expect(app.selected == "t:viewer" && app.state { TrackerUI() }.open.contains("viewer"))
        #expect(app.state { TrackerUI() }.list == nil)
    }

    @Test func openingForestWorkKeepsItsExactList() {
        let app = app()
        app.focus(pane: "work")
        app.keys.handle("ret")
        #expect(app.router.route == .todo && app.selected == "t:forest")
        #expect(app.state { TrackerUI() }.list == "r:tree")
    }

    @Test func readyOnlyAndCompletedWorkLeaveNoInvisiblePane() throws {
        let app = app()
        app.forestModel.readyOnly = true
        #expect(app.panes.map(\.id) == ["main"])
        app.forestModel.readyOnly = false
        let patch = try Patch.make(domain: Domain.todo, version: 2, upserts: ["todo": ["forest": ["id": "forest", "state": "done"], "viewer": ["id": "viewer", "state": "done"]]])
        #expect(app.store.applyPatch(patch) == .ok)
        #expect(app.panes.map(\.id) == ["main"])
    }

    @Test func ownerIsAnAssignmentAndNeverAWorkingHeartbeat() throws {
        let app = app(), item = try #require(app.store.trackerItem("viewer"))
        #expect(WorkContext.owner(item, app.store) == "assigned to session session-a")
        var done = item; done.state = .done
        #expect(WorkContext.owner(done, app.store) == nil)
        #expect(KeyboardRule.violations(app) { $0.hasPrefix("todo.") }.isEmpty)
        #expect(app.registry.keyProblems.isEmpty)
    }

    @Test func disappearingWorkKeepsAnHonestEmptyPaneUntilTheReaderLeaves() throws {
        let app = app()
        app.focus(pane: "work")
        let focus = app.focusGeneration
        app.store.addOps([Op(seq: 99, type: .todo, id: "forest", fields: ["state": "done"]),
                          Op(seq: 99, type: .todo, id: "viewer", fields: ["state": "done"])])
        #expect(app.pane?.id == "work" && app.rows.isEmpty && WorkInProgressView.visible(app))
        app.keys.handle("C-w"); app.keys.handle("j")
        #expect(app.pane?.id == "main" && app.focusGeneration > focus)
        let main = app.selected
        #expect(!app.panes.contains { $0.id == "work" })
        app.store.dropOps(seq: 99)
        #expect(app.panes.contains { $0.id == "work" })
        #expect(app.pane?.id == "main" && app.selected == main)
    }

    @Test func aReadyFilterRoundTripCannotStealFocusBackFromMain() {
        let app = app()
        app.focus(pane: "work")
        app.forestModel.readyOnly = true
        #expect(app.pane?.id == "work" && app.rows.isEmpty && WorkInProgressView.visible(app))
        app.keys.handle("C-w"); app.keys.handle("j")
        #expect(app.pane?.id == "main")
        let focus = app.focusGeneration
        app.forestModel.readyOnly = false
        #expect(app.pane?.id == "main" && app.focusGeneration == focus)
    }

    @Test func aCompletedInputCanBeOpenedWithoutReopeningTheWork() throws {
        let app = app()
        app.runner.dispatch("todo.show", via: .key, arg: "closed")
        #expect(app.router.route == .todo && app.selected == "t:closed")
        #expect(app.rows.contains("t:closed"))
        #expect(app.state { TrackerUI() }.sections(app.store).last?.section == .recorded)
        #expect(app.state { TrackerUI() }.open.contains("closed"))
        #expect(app.store.trackerItem("closed")?.state == .done)
        #expect(RecordedWorkInput.read(try #require(app.store.trackerItem("closed")).body)?.text == "Keep the latest direction visible.")
        app.runner.dispatch("todo.show", via: .key, arg: "viewer")
        #expect(!app.rows.contains("t:closed") && app.selected == "t:viewer")
        #expect(app.store.trackerItem("closed")?.state == .done)
    }
}

@Suite struct WorkFreshnessViewTests {
    static func decoded(_ json: String) throws -> TodoItem {
        try JSONDecoder().decode(TodoItem.self, from: Data(json.utf8))
    }

    static let pendingAfterDone = """
    {"id": "item", "title": "Item", "kind": "build", "state": "done", "area": "native", "size": "M", "why": "w", "body": "",
     "work": {"work_id": "w_1", "revision": 3, "order": "source", "in_force": 3, "superseded": 0, "unassigned": 0, "coverage": "complete",
              "latest": {"message_id": "m_3", "text": "also show last touch", "truncated": false, "source": "show", "conversation": "d#s",
                         "seq": 3, "source_time": "2026-11-17T18:05:00Z", "received_at": "2026-11-17T18:05:01.000Z"},
              "delivered": {"revision": 2, "boundary": "turn", "state": "acknowledged", "at": "2026-11-17T18:01:00Z", "acknowledged_revision": 2},
              "worker": {"host": "claude-headless", "managed": true, "generation": 1, "state": "ended", "outcome": "succeeded"},
              "progress": {"text": "halfway", "truncated": false, "at": "2026-11-17T18:02:00.000Z", "verdict_at_report": "current",
                           "delivered_revision": 2, "generation": 1, "basis": "older"},
              "completion": "historical", "answered_revision": 2, "state": "pending"}}
    """

    @Test func newDirectionAfterADoneItemReopensItEverywhere() throws {
        let item = try Self.decoded(Self.pendingAfterDone)
        let w = try #require(item.work)
        #expect(w.revision == 3 && w.answeredRevision == 2 && w.progress?.basis == "older" && w.latest?.seq == 3)
        #expect(WorkContext.reopened(item) && Tracker.sectionOf(item) == .doing)
        let context = WorkContext([item], subject: .viewer)
        #expect(context.reopened.map(\.id) == ["item"] && context.summary.contains("1 with new direction"))
        #expect(WorkContext.status(item) == "marked done · new direction since")
        let line = WorkContext.freshness(w)
        #expect(line.contains("direction r3") && line.contains("delivered r2 confirmed") && line.contains("worker ended (succeeded)"))
        #expect(line.contains("done for r2 · newer direction pending") && !line.contains("done for r3"))
        let progress = try #require(w.progress)
        #expect(WorkContext.progress(progress) == "progress 2026-11-17 18:02 UTC · on older direction")
    }

    @Test func unknownCoverageKeepsKnownNewDirectionOpenButNeverAnswered() throws {
        var item = try Self.decoded(Self.pendingAfterDone)
        item.work?.state = "unknown"
        item.work?.coverage = "unknown"
        #expect(WorkContext.reopened(item) && Tracker.sectionOf(item) == .doing)
        let unknown = try #require(item.work)
        let line = WorkContext.freshness(unknown)
        #expect(line.contains("freshness unknown") && line.contains("newer direction pending") && !line.contains("done for r"))

        item.work?.revision = 2
        item.work?.completion = "current"
        #expect(!WorkContext.reopened(item) && Tracker.sectionOf(item) == nil)
        let same = try #require(item.work)
        let disconnected = WorkContext.freshness(same)
        #expect(disconnected.contains("capture unknown · freshness unknown · done recorded for r2") && !disconnected.contains("pending"))
    }

    @Test func answeredWorkIsDoneAndUnreadableWorkClaimsNothing() throws {
        var item = try Self.decoded(Self.pendingAfterDone)
        item.work?.revision = 2
        item.work?.state = "answered"
        item.work?.completion = "current"
        let answered = try #require(item.work)
        #expect(!WorkContext.reopened(item) && WorkContext.freshness(answered).hasSuffix("done for r2"))
        let unreadable = try Self.decoded(#"{"id": "u", "state": "done", "work": {"state": "unavailable", "reason": "work journal unreadable: DatabaseError"}}"#)
        #expect(unreadable.work?.state == "unavailable" && unreadable.work?.revision == nil && !WorkContext.reopened(unreadable))
        let unreadableWork = try #require(unreadable.work)
        #expect(WorkContext.freshness(unreadableWork) == "work journal unreadable · freshness unknown")
        #expect(WorkContext.direction(unreadable) == nil)
        #expect(WorkInputView.label(nil, unreadable.work) == "Work journal unreadable · latest instruction unknown")
    }

    @Test func aLaterUncitedReportKeepsTheQualifiedAnswerInView() throws {
        var item = try Self.decoded(Self.pendingAfterDone)
        item.work?.completion = "unverified"
        let unverified = try #require(item.work)
        #expect(WorkContext.reopened(item) && Tracker.sectionOf(item) == .doing)
        let line = WorkContext.freshness(unverified)
        #expect(line.hasSuffix("done for r2 · newer direction pending · last report unverified"), "\(line)")
        item.work?.completion = "stale"
        let stale = try #require(item.work)
        #expect(WorkContext.freshness(stale).hasSuffix("done for r2 · newer direction pending · last report stale"))
        item.work?.answeredRevision = nil
        item.work?.completion = "unverified"
        let never = try #require(item.work)
        #expect(WorkContext.freshness(never).hasSuffix("completion unverified") && !WorkContext.freshness(never).contains("done for"))
    }

    @Test func staleAndUnconfirmedDeliveriesAreSaidPlainly() throws {
        var w = try #require(Self.decoded(Self.pendingAfterDone).work)
        w.completion = "stale"
        w.answeredRevision = nil
        w.delivered?.state = "uncertain"
        w.worker = .init(host: "claude-say", state: "unknown")
        let line = WorkContext.freshness(w)
        #expect(line.contains("last completion stale") && !line.contains("answered older"))
        #expect(line.contains("delivered r2 unconfirmed") && line.contains("worker state unknown"))
        w.delivered = nil
        w.worker = nil
        #expect(WorkContext.freshness(w).contains("not delivered") && !WorkContext.freshness(w).contains("worker"))
    }

    @Test func theJournalsLiteralMessageOutranksTheRecordedSection() throws {
        var item = try Self.decoded(Self.pendingAfterDone)
        item.body = WorkContextTests.body("An older recorded convention", at: "2026-11-30T18:00:00Z")
        guard case .journal(let latest) = WorkContext.direction(item) else { Issue.record("journal direction expected"); return }
        #expect(latest.text == "also show last touch")
        #expect(WorkInputView.label(WorkContext.direction(item), item.work).hasPrefix("Your latest instruction · sent 2026-11-17 18:05 UTC"))
        let legacy = TodoItem(id: "legacy", body: WorkContextTests.body("Recorded by hand"))
        #expect(WorkInputView.label(WorkContext.direction(legacy), nil).hasSuffix("not captured by the work journal"))
        var ambiguous = item
        ambiguous.work?.latest = nil
        ambiguous.work?.order = "ambiguous"
        #expect(WorkContext.direction(ambiguous) == nil)
        #expect(WorkInputView.label(nil, ambiguous.work) == "Instructions from more than one conversation · no single latest")
        let scope = WorkContext([legacy, item], subject: .viewer)
        #expect(scope.latestDirection?.item.id == "item")
    }

    @Test func workBackedItemsStayVisibleWithoutASingleLatestMessage() throws {
        var ambiguous = try Self.decoded(Self.pendingAfterDone)
        ambiguous.work?.latest = nil
        ambiguous.work?.order = "ambiguous"
        var shown = try #require(WorkContext([ambiguous], subject: .viewer).presentation)
        #expect(shown.item.id == "item" && shown.direction == nil)
        #expect(WorkInputView.label(shown.direction, shown.item.work) == "Instructions from more than one conversation · no single latest")
        #expect(WorkContext.freshness(try #require(shown.item.work)).contains("direction r3"))

        let unreadable = try Self.decoded(#"{"id": "u", "state": "doing", "work": {"state": "unavailable", "reason": "r"}}"#)
        shown = try #require(WorkContext([unreadable], subject: .viewer).presentation)
        #expect(shown.item.id == "u" && WorkInputView.label(shown.direction, shown.item.work) == "Work journal unreadable · latest instruction unknown")

        let empty = TodoItem(id: "e", state: .doing, work: WorkFreshness(state: "unknown", revision: 0, order: "none", coverage: "unknown"))
        shown = try #require(WorkContext([empty], subject: .viewer).presentation)
        #expect(shown.item.id == "e" && WorkInputView.label(shown.direction, shown.item.work) == "No instruction captured")

        let legacy = TodoItem(id: "legacy", state: .doing)
        #expect(WorkContext([legacy], subject: .viewer).presentation == nil)
        #expect(WorkInputView.label(nil, nil) == "No chat instruction recorded")

        let queued = TodoItem(id: "a-queued", work: WorkFreshness(state: "unknown", revision: 0, order: "none"))
        #expect(WorkContext([queued, empty, ambiguous, legacy], subject: .viewer).presentation?.item.id == "item",
                "reopened work comes first, then work in progress, never a guessed latest across items")
    }

    @Test func theLastProgressStatementIsReadableWhereTheRecordIsReadInFull() throws {
        let item = try Self.decoded(Self.pendingAfterDone)
        #expect(WorkInputView.progressText(item.work, expanded: true) == "halfway")
        #expect(WorkInputView.progressText(item.work, expanded: false) == nil)
        #expect(WorkInputView.progressText(nil, expanded: true) == nil)
    }

    @Test func sourceTimesAreShownInUTCWhateverTheirOffset() throws {
        var item = try Self.decoded(Self.pendingAfterDone)
        item.work?.latest?.sourceTime = "2026-11-17T14:00:00-08:00"
        #expect(WorkInputView.label(WorkContext.direction(item), item.work) == "Your latest instruction · sent 2026-11-17 22:00 UTC")
        item.work?.latest?.sourceTime = nil
        #expect(WorkInputView.label(WorkContext.direction(item), item.work) == "Your latest instruction · received 2026-11-17 18:05 UTC")
        item.work?.latest?.sourceTime = "yesterday afternoon"
        #expect(WorkInputView.label(WorkContext.direction(item), item.work) == "Your latest instruction · sent at \"yesterday afternoon\" (time not understood)")
    }

    @Test func doingNowIsTheFirstNextStepElseTheWhy() {
        let steps = "Native ownership is done.\n\n## Next steps\n\n- [ ] Mint a **per-editor** `lease`.\n- Prove ownership.\n\n## Done\n\n- old"
        #expect(WorkContext.doingNow(TodoItem(id: "a", why: "why it matters", body: steps)) == "Mint a per-editor lease.")
        #expect(WorkContext.doingNow(TodoItem(id: "b", why: "why it matters", body: "## Next steps\n\nprose only\n## Done\n- x")) == "why it matters")
        #expect(WorkContext.doingNow(TodoItem(id: "c", why: "  ")) == nil)
    }

    @MainActor @Test func workLandsOnTheOneBranchItNames() throws {
        let base = try ShipControlTests().branch()
        func b(_ id: String, _ name: String, _ project: String) -> Branch { var x = base; x.id = id; x.name = name; x.project = project; return x }
        let branches = [b("r:a", "feat/a", "r:fx"), b("r:dup1", "dup", "r:fx"), b("s:dup2", "dup", "s:fy"), b("s:a2", "feat/b", "s:fy")]
        let items = [TodoItem(id: "viewer", state: .doing, solved_by: "feat/a"),
                     TodoItem(id: "forest", state: .doing, project: "r:fx", solved_by: "feat/a"),
                     TodoItem(id: "wrong-forest", state: .doing, project: "r:other", solved_by: "feat/a"),
                     TodoItem(id: "ambiguous", state: .doing, solved_by: "dup"),
                     TodoItem(id: "scoped", state: .doing, project: "s:fy", solved_by: "dup"),
                     TodoItem(id: "unbound", state: .doing)]
        let placed = WorkContext.onBranches(items, branches)
        #expect(placed["r:a"]?.map(\.id) == ["viewer", "forest"])
        #expect(placed["s:dup2"]?.map(\.id) == ["scoped"])
        #expect(placed.count == 2)
    }

    @Test func aChatIsOnTheBranchesItActedOnOrIsBoundTo() {
        typealias C = WorkContext.Chat
        let byBranch = C(id: "aaaaaaaa-1", works: [.init(work: "w_a", todo: nil)], generation: 1, pane: "%1", activeAt: 1000)
        let byItem = C(id: "bbbbbbbb-2", works: [.init(work: "w_item", todo: "item")], generation: 2, pane: nil, activeAt: 0)
        let acting = C(id: "eeeeeeee-5", works: [], generation: 0, pane: "%5", activeAt: 1000,
                       acted: [.init(branch: "r:c", how: "commit", at: 880), .init(branch: "r:c", how: "edit", at: 940), .init(branch: "r:unlisted", how: "edit", at: 990)])
        let loose = C(id: "cccccccc-3", works: [], generation: 0, pane: "%3", activeAt: 1000)
        let unknown = C(id: "dddddddd-4", works: nil, generation: 0, pane: nil, activeAt: 1000)
        let on = WorkContext.chatsOnBranches([byBranch, byItem, acting, loose, unknown], branches: ["r:a", "r:b", "r:c"],
                                             branchWork: ["r:a": "w_a", "r:b": "w_b"],
                                             placed: ["r:b": [TodoItem(id: "item", state: .doing, solved_by: "b")]])
        #expect(on["r:a"] == [byBranch], "the branch's own work names it")
        #expect(on["r:b"] == [byItem], "an item placed on the branch brings its chats")
        #expect(on["r:c"] == [acting], "a chat that acted on a branch is on it, unbound")
        #expect(on.count == 3, "a chat that neither acted on nor is bound to a listed branch is on none")
        #expect(WorkContext.chatsLine([acting], on: "r:c", now: 1000) == "chat eeeeeeee live · edited 1m ago", "its latest action there, in words")
        #expect(WorkContext.chatLabel(byItem, on: "r:b", now: 1100) == "chat bbbbbbbb idle · bound")
        let onDots = Set(on.values.flatMap { $0.map(\.id) })
        #expect(WorkContext.onNoWork([byBranch, byItem, acting, loose, unknown], onDots: onDots).map(\.id) == ["cccccccc-3", "dddddddd-4"])
    }

    @Test func focusingAChatRunsClaudeJumpWithItsFullId() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("chat-jump-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("jump"), out = dir.appendingPathComponent("args")
        try "#!/bin/sh\necho \"$@\" > \(out.path)\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        setenv("SHOW_CLAUDE_JUMP", script.path, 1)
        defer { unsetenv("SHOW_CLAUDE_JUMP") }
        #expect(ChatJump.run("aaaaaaaa-0000-4000-8000-000000000001") == nil)
        #expect((try? String(contentsOf: out, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) == "aaaaaaaa-0000-4000-8000-000000000001")
        try "#!/bin/sh\necho 'claude-jump: 0 sessions match' >&2\nexit 1\n".write(to: script, atomically: true, encoding: .utf8)
        #expect(ChatJump.run("gone") == "claude-jump: 0 sessions match", "a failure comes back in claude-jump's words")
    }

    @Test func aChatOnNoBranchSaysWhereItStandsAndNothingMore() {
        typealias C = WorkContext.Chat
        let loose = C(id: "bbbbbbbb-2", works: [], generation: 0, pane: nil, activeAt: 1000, at: .init(repo: "loops-wt-2", branch: "feat/x"))
        let unread = C(id: "cccccccc-3", works: nil, generation: 0, pane: nil, activeAt: 0, at: .init(repo: ".dotfiles", branch: ""))
        #expect(WorkContext.onNoWork([unread, loose], onDots: []) == [loose, unread], "most recent first")
        #expect(WorkContext.whereItStands(loose, now: 1100) == "chat bbbbbbbb live · in loops-wt-2 · feat/x")
        #expect(WorkContext.whereItStands(unread, now: 1100) == "chat cccccccc idle · in .dotfiles · binding unreadable")
    }
}
