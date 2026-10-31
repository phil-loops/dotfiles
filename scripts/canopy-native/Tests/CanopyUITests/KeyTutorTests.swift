import CanopyCore
import Foundation
import Testing
@testable import CanopyUI

/// The keytutor, driven by keys through the host app the way KeyMonitor drives it. Every request the
/// practice app makes is answered by KeyTutorStub; progress lives in memory.
@MainActor @Suite(.serialized) struct KeyTutorTests {
    nonisolated(unsafe) static var nextPort = 45_100

    /// A host app (its own requests stubbed too, so any would be seen), the keytutor open on it.
    func host(_ progress: KeyTutorProgress? = nil, keys: [String: [String]] = [:]) throws -> (AppModel, KeyTutor, Int) {
        Self.nextPort += 1
        let p = Self.nextPort
        KeyTutorStub.open(p)
        let a = AppModel(config: AppConfig(), port: p, telemetry: false, protocolClasses: [KeyTutorStub.self])
        if !keys.isEmpty { a.registry.applyUserKeys(keys) }
        let t = KeyTutor.of(a)
        t.store = MemoryProgress(progress)
        try t.open(nil)
        return (a, t, p)
    }

    func until(_ what: String, timeout: Double = 3, _ ok: () -> Bool) async -> Bool {
        let t0 = Date()
        while !ok() {
            if Date().timeIntervalSince(t0) > timeout { Issue.record("timed out waiting for \(what)"); return false }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return true
    }

    func press(_ a: AppModel, _ seq: String) { for k in seq.split(separator: " ") { a.keys.handle(String(k)) } }

    /// The key a verb has right now in the practice app's live mode (never ↵ for send in a many-line box).
    func keyOf(_ sb: AppModel, _ v: Verb) -> String {
        let vk = sb.registry.verbKeys
        var ks = vk.of(v, in: sb.keys.active)
        if ks.isEmpty { ks = vk.keys[v] ?? [] }
        if sb.keys.active == .insert && sb.keys.fieldLines == .multi && v == .send { ks.removeAll { $0 == "ret" } }
        return ks.min { ($0.split(separator: " ").count, $0.count) < ($1.split(separator: " ").count, $1.count) } ?? ""
    }

    /// Labels need geometry the views report; headless, say where every row of the practice page is.
    func noteRows(_ sb: AppModel) {
        for (c, p) in sb.panes.enumerated() {
            for (i, r) in p.rows.enumerated() {
                sb.noteTarget(LabelTarget(pane: p.id, key: r, rect: CGRect(x: Double(c) * 400, y: Double(i) * 20, width: 300, height: 18)))
            }
        }
    }

    /// Do one step the way a person would: the step's verb by its current key, plus whatever typing
    /// the step asks for.
    func act(_ a: AppModel, _ t: KeyTutor, _ sb: AppModel) async {
        let l = t.lesson.id, i = t.stepIndex
        guard let s = t.step else { return }
        switch (l, i) {
        case ("modes", 2): press(a, String(keyOf(sb, .goForests).split(separator: " ")[0]))
        case ("labels", 0): noteRows(sb); press(a, keyOf(sb, .labels))
        case ("labels", 1):
            guard let label = sb.labeling?.label("main", RowKey.branch(KeyTutorSandbox.id(KeyTutorSandbox.footer))) else {
                Issue.record("no label on the footer row: \(String(describing: sb.labeling?.items.map(\.key)))"); return
            }
            press(a, label.map(String.init).joined(separator: " "))
        case ("jumps", 1): sb.nav.typed("foot"); press(a, keyOf(sb, .send))
        case ("code", 1): ReviewPageState.of(sb).filter = "head"; press(a, keyOf(sb, .send))
        case ("code", 3): sb.nav.typed("wave"); press(a, keyOf(sb, .send))
        case ("writing", 0):
            let ship = ShipState.of(sb)
            if let c = ship.composer { ship.setText(c.key, "reads well") }   // what typing into the box does
            press(a, "ret")   // ↵ in the comment box: a new line, never a send
        case ("shared", 1): try? await Task.sleep(nanoseconds: 150_000_000); press(a, keyOf(sb, .undo))
        case ("shared", 3): press(a, "esc"); press(a, "esc")
        case ("shared", 9):
            _ = await until("the words rows") { sb.rows.contains("w|title") }
            sb.setCursor("w|title")
            press(a, keyOf(sb, .copy))
        case ("leader", 1): press(a, "o")
        case ("leader", 2): press(a, keyOf(sb, .leader)); press(a, "o")
        case ("help", 1): sb.cmdline = "go todo"; press(a, keyOf(sb, .send))
        default:
            guard let v = s.wants.first else { Issue.record("\(l) \(i): no verb and no script"); return }
            press(a, keyOf(sb, v))
        }
    }

    /// Every lesson, step by step, by key: each finishes, and nothing leaves the practice app.
    @Test func aScriptedRunThroughEveryLessonCompletesThemAll() async throws {
        let (a, t, hostPort) = try host()
        let sb = try #require(t.sandbox)
        #expect(a.router.route == .keytutor(lesson: nil))
        var steps = 0
        var turns = 0
        while !t.finished {
            turns += 1
            if turns > 400 { Issue.record("runaway at \(t.lesson.id) \(t.stepIndex)"); break }
            if t.recapping {
                let from = t.lesson.id
                press(a, keyOf(sb, .main))
                if t.recapping { Issue.record("↵ didn't go on from \(from)'s recap (mode \(sb.keys.active.rawValue))"); t.goOn() }
                await Task.yield()
                continue
            }
            let at = (t.lessonIndex, t.stepIndex)
            let name = "\(t.lesson.id) step \(t.stepIndex + 1): \(t.plain(t.step?.text ?? ""))"
            guard await until("\(name) to be ready", { t.ready }) else { t.skip(); continue }
            await act(a, t, sb)
            let moved = await until(name, timeout: 2) { (t.lessonIndex, t.stepIndex) != at || t.recapping || t.finished }
            if !moved {
                Issue.record("\(name) didn't finish · practice at \(sb.router.route.path) · mode \(sb.keys.active.rawValue) · here \(ReviewPageState.of(sb).here?.key ?? "-") · note \(sb.runner.note ?? "-") · picker \(sb.nav.picker?.title ?? "-") · composer \(String(describing: ShipState.of(sb).composer))")
                t.skip()
            }
            steps += 1
            #expect(a.router.route.surfaceID == "keytutor", "\(name) left the keytutor")
        }
        #expect(steps == KeyTutor.lessons.reduce(0) { $0 + $1.steps.count })
        #expect(t.done == Set(KeyTutor.lessons.map(\.id)))

        // nothing escaped: every request went to the practice stub on the practice app's own port,
        // the host asked for nothing, and what would have opened or been copied was only noted
        try? await Task.sleep(nanoseconds: 300_000_000)
        let port = sb.config.port!
        let seen = KeyTutorStub.requests(port)
        #expect(!seen.isEmpty)
        #expect(seen.allSatisfy { $0.host == "127.0.0.1" && $0.port == port })
        #expect(KeyTutorStub.requests(hostPort).isEmpty, "\(KeyTutorStub.requests(hostPort))")
        let writes = Set(seen.filter { $0.method == "POST" }.map(\.path))
        let expected: Set<String> = ["/practice/viewed", "/practice/review-draft", "/practice/outline", "/practice/review-apply",
                                     "/practice/review-unapply", "/practice/sync", "/practice/prep-push", "/practice/gates",
                                     "/practice/delta-tests", "/practice/open", "/practice/todo-item", "/todo-item",
                                     "/practice/lsp/hover", "/practice/lsp/definition", "/practice/lsp/type-definition",
                                     "/practice/lsp/implementation", "/practice/lsp/references", "/practice/lsp/symbols",
                                     "/practice/push-origin", "/practice/integrate", "/practice/lsp/prepare", "/practice/revert-commit"]
        #expect(writes.isSubset(of: expected), "unexpected writes: \(writes.subtracting(expected).sorted())")
        let notes = KeyTutorStub.notes(port)
        #expect(notes.contains { $0.hasPrefix("open https://github.invalid/") || $0.hasPrefix("open http://127.0.0.1") }, "\(notes)")
        #expect(notes.contains { $0.hasPrefix("copy ") })
    }

    /// Steps want verbs, not keys: move mark and the step's text shows the new key, and the new key finishes it.
    @Test func reboundVerbRendersItsNewKeyAndStillFinishesTheStep() async throws {
        let (a, t, _) = try host(keys: ["mark": ["Z"]])
        let sb = try #require(t.sandbox)
        let review = try #require(KeyTutor.lessons.firstIndex { $0.id == "review" })
        let markStep = try #require(KeyTutor.lessons[review].steps.firstIndex { $0.wants == [.mark] })
        t.go(lesson: review, step: markStep)
        _ = await until("ready") { t.ready }
        #expect(t.render(t.step!.text).contains(KeyTutorPiece(text: "⇧z", key: true)))
        #expect(!t.plain(t.step!.text).contains(" m "))
        press(a, "m")
        #expect(t.stepIndex == markStep, "the old key is nothing now")
        press(a, "Z")
        #expect(t.stepIndex == markStep + 1)
        // a miss or two, and the hint names the verb and your key for it
        press(a, "q"); press(a, "q")
        #expect(t.hint == "this step wants previous-hunk — your key is {")
        _ = sb
    }

    @Test func progressResumesAndIsSavedAsYouGo() async throws {
        let store = MemoryProgress(KeyTutorProgress(lesson: "stack", step: 2, done: ["modes", "moving"]))
        Self.nextPort += 1
        let a = AppModel(config: AppConfig(), port: Self.nextPort, telemetry: false, protocolClasses: [KeyTutorStub.self])
        let t = KeyTutor.of(a)
        t.store = store
        try t.open(nil)
        #expect(t.lesson.id == "stack" && t.stepIndex == 2 && t.done == ["modes", "moving"])
        t.skip()
        #expect(store.saved == KeyTutorProgress(lesson: "stack", step: 3, done: ["modes", "moving"]))
        #expect(FileProgress.defaultURL.path.hasSuffix("Application Support/canopy-native/keytutor.json"))
    }

    /// `:keytutor review` jumps (fuzzily) and comes from where you were; esc that cancels nothing leaves, back there.
    @Test func colonKeytutorJumpsAndEscLeavesBackToWhereYouWere() async throws {
        Self.nextPort += 1
        let a = AppModel(config: AppConfig(), port: Self.nextPort, telemetry: false, protocolClasses: [KeyTutorStub.self])
        KeyTutor.of(a).store = MemoryProgress()
        a.go(.todo)
        press(a, ":")
        a.cmdline = "keytutor revie"
        #expect(a.completions.first?.id == "keytutor")
        press(a, "ret")
        let t = KeyTutor.of(a)
        #expect(a.router.route.surfaceID == "keytutor" && t.lesson.id == "review")
        let sb = try #require(t.sandbox)
        // inside: : is the practice app's command line, and esc backs out of it without leaving
        press(a, ":")
        #expect(sb.keys.mode == .command && a.keys.mode == .normal)
        press(a, "esc")
        #expect(a.router.route.surfaceID == "keytutor")
        press(a, "esc")
        #expect(a.router.route == .todo, "nothing left to cancel: back where you were")
        // and back in, where you left off
        try t.open(nil)
        #expect(a.router.route.surfaceID == "keytutor" && t.lesson.id == "review")
        #expect(throws: Refusal.self) { try t.open("zzzz") }
    }

    /// Every verb in the table is taught by some lesson, but for the justified few.
    @Test func everyVerbIsTaught() {
        let taught = Set(KeyTutor.lessons.flatMap(\.teaches))
        for v in Verb.allCases where KeyLessons.untaught[v] == nil {
            #expect(taught.contains(v), "no lesson teaches \(v.name)")
        }
        for (v, why) in KeyLessons.untaught { #expect(!why.isEmpty && !taught.contains(v)) }
        #expect(Set(KeyTutor.lessons.map(\.id)).count == KeyTutor.lessons.count)
        for l in KeyTutor.lessons {
            for s in l.steps {
                for name in s.text.split(separator: "{").dropFirst().map({ String($0.prefix { $0 != "}" }) }) {
                    #expect(Verb(rawValue: name) != nil, "\(l.id): {\(name)} is no verb")
                }
            }
        }
    }

    /// The keytutor's own keys keep the rules, in the host and in the practice app, and its `, k`
    /// keys collide with no page's leader keys.
    @Test func theKeytutorsKeysKeepTheRules() throws {
        let (a, t, _) = try host()
        let sb = try #require(t.sandbox)
        #expect(KeyboardRule.violations(a) { $0.hasPrefix("keytutor") } == [])
        #expect(KeyboardRule.violations(sb) == [])
        #expect(a.registry.keyProblems.isEmpty && sb.registry.keyProblems.isEmpty, "\(sb.registry.keyProblems)")
        let leader = sb.registry.verbKeys.leader
        let pageKeys = sb.registry.commands.filter { $0.leader != nil && $0.scope != .practice }.map { $0.leader!.key(leader: leader) }
        #expect(!pageKeys.contains { $0 == "\(leader) k" || $0.hasPrefix("\(leader) k ") })
        #expect(sb.liveScopes().contains(.practice) && !a.liveScopes().contains(.practice))
        #expect(sb.registry.command("keytutor.skip")?.keys == [", k s"])
    }
}
