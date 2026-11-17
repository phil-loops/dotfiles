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
