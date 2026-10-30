import CanopyCore
import Foundation

/// The tutor's moves (commands/tutor.ts). Starting or answering a session spends a model call
/// (POST /tutor, streamed); a question you raise and every audit of a credit are graph writes
/// (POST /learning-question, /learning-evidence), each with its undo where one exists. Forgetting
/// a session and cutting a credit take a second press.
///
/// Native additions, all to keep the page mouseless: `tutor.submit` (send, ↵ in insert: what's
/// typed in whichever box), `tutor.concept.show` (ret's target when a row is a concept),
/// `tutor.confidence.low/medium/high` (1–3, the rating chips), `tutor.question.toggle` (m, the
/// answered/reopen link), and `tutor.evidence.outcome/level/credit/confidence` (, o / , l / , h / , c,
/// the credit's toggles and dropdowns).
@MainActor
enum TutorCommands {
    static let insertField = (draft: "tutor.draft", target: "tutor.target", question: "tutor.question")

    static func install(_ app: AppModel, _ t: TutorState) {
        let r = app.registry
        let known: (String?) -> Bool = { [weak t] id in t?.concept(id) != nil }
        let kept: (String?) -> Bool = { [weak t] id in id != nil && (t?.sessions.contains { $0.id == id } ?? false) }
        let idle: () -> Bool = { [weak t] in !(t?.streaming ?? true) }


        // ── going places ──

        r.register(Command(
            id: "tutor.concept", title: "Open the concept: its depth, evidence and questions", scope: .concept, verb: .main, label: "open",
            available: known,
            // ret is the row's main action; on a row that has none, it opens the concept in reach
            route: { [weak app] id in
                guard let app else { return nil }
                if let row = app.selected, let p = app.provider?.primary(for: row, app) { return p }
                return known(id) ? RouteTo("tutor.concept.show", target: id) : nil
            }))
        r.register(Command(
            id: "tutor.concept.show", title: "Open a concept in the drawer", scope: .concept, needsArg: true, quiet: true,
            available: known,
            local: { [weak t] id, _ in
                guard let t, let id else { return }
                if t.drawer != id { t.openDrawer(id) }
            }))
        r.register(Command(
            id: "tutor.open", title: "Open the session", scope: .lesson, verb: .main, label: "open", v1: ["click:continue"],
            available: kept,
            local: { [weak t, weak app] id, _ in
                t?.closeDrawer()
                app?.go(.tutor(session: id))
            }))
        r.register(Command(
            id: "tutor.home", title: "Leave the session for your graph", scope: .session, verb: .out, label: "home", v1: ["click:your graph"],
            local: { [weak t, weak app] _, _ in
                t?.closeDrawer()
                app?.go(.tutor(session: nil))
            }))
        r.register(Command(
            id: "tutor.back", title: "Back out", scope: .tutor, verb: .cancel, label: "back", v1: ["click:close (esc)"], quiet: true,
            local: { [weak t, weak app] _, _ in
                guard let t, let app else { return }
                if CodeLookup.of(app).pop != nil { CodeLookup.of(app).dismiss() }
                else if t.armed != nil { t.armed = nil }
                else if t.drawer != nil { t.closeDrawer() }
                else if t.evidenceOpen { t.evidenceOpen = false }
                else if let c = app.closers.first(where: { $0.isOpen() }) { c.close() }
                else { throw Refusal("nothing to close") }
            }))
        r.register(Command(
            id: "find.concept", title: "Open a concept you found", scope: .global, needsArg: true, quiet: true,
            local: { [weak t, weak app] _, arg in
                guard let t, let app, let id = arg as? String else { throw Refusal("no concept") }
                app.go(.tutor(session: nil))
                t.load()
                t.openDrawer(id)
            }))

        // ── starting and answering (each spends a model call) ──

        r.register(Command(
            id: "tutor.start", title: "Start a session on what's typed", scope: .tutor, budget: .slowIO, v1: ["click:start"],
            available: { [weak t] _ in idle() && !(t?.target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) },
            local: { [weak t, weak app] _, _ in
                guard let t else { return }
                t.start(t.target.trimmingCharacters(in: .whitespacesAndNewlines))
                t.target = ""
                app?.keys.setMode(.normal)
            }))
        r.register(Command(
            id: "tutor.retest", title: "Re-test me cold on the concept", scope: .concept, budget: .slowIO, leader: LocalKey(",t"), label: "re-test",
            v1: ["click:re-test cold", "click:re-test me cold"],
            available: { known($0) && idle() },
            local: { [weak t] id, _ in
                guard let t, let c = t.concept(id) else { return }
                t.start("Re-test me cold on \(c.name) [\(c.id)]", topic: c.topics.first)
            }))
        r.register(Command(
            id: "tutor.teach", title: "Teach me the concept", scope: .concept, budget: .slowIO, v1: ["click:teach me this"],
            available: { known($0) && idle() },
            local: { [weak t] id, _ in
                guard let t, let c = t.concept(id) else { return }
                t.start("Teach me \(c.name) [\(c.id)]: \(c.statement)", topic: c.topics.first)
            }))
        r.register(Command(
            id: "tutor.topic", title: "Continue a topic from its weakest concept", scope: .topic, budget: .slowIO, quiet: true,
            available: { [weak t] id in id != nil && t?.learn?.topics[id!] != nil && idle() },
            local: { [weak t] id, _ in
                guard let t, let id, let tp = t.learn?.topics[id] else { return }
                t.start("Continue \(tp.title) [\(tp.id)] — start from what my graph says is weakest", topic: tp.id)
            }))
        r.register(Command(
            id: "tutor.pursue", title: "Pursue an open question in a session", scope: .question, budget: .slowIO, v1: ["click:pursue"], quiet: true,
            available: { [weak t] id in (t?.learn?.questions.contains { $0.id == id } ?? false) && idle() },
            local: { [weak t] id, _ in
                guard let t, let q = t.learn?.questions.first(where: { $0.id == id }) else { return }
                t.start("My open question: \(q.text)", topic: q.topic.isEmpty ? nil : q.topic)
            }))

        /// The answer box's text, rated when the rung asks for it: ret without a rating flags the
        /// chips once; a second ret sends without one rather than trapping the answer.
        r.register(Command(
            id: "tutor.send", title: "Send your answer", scope: .session, budget: .slowIO,
            available: { [weak t] _ in t?.active != nil && idle() && !(t?.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) },
            local: { [weak t, weak app] _, _ in
                guard let t, let s = t.active else { return }
                let text = t.draft
                if t.wantsConfidence && t.confidence == nil && !t.askedConfidence {
                    t.askedConfidence = true
                    return
                }
                if t.answer(s.id, t.confidence.map { "\(text) (confidence: \($0))" } ?? text) != nil {
                    t.draft = ""
                    t.expanded = nil
                    t.confidence = nil
                    t.askedConfidence = false
                    app?.keys.setMode(.normal)
                }
            }))
        r.register(Command(
            id: "tutor.submit", title: "Send what's typed", scope: .tutor, verb: .send, modes: [.insert], label: "send", quiet: true,
            route: { [weak t, weak app] _ in
                switch app?.insertField {
                case insertField.draft: return RouteTo("tutor.send")
                case insertField.target: return RouteTo("tutor.start")
                case insertField.question: return t?.drawer.map { RouteTo("tutor.ask", target: $0) }
                default: return nil
                }
            }))
        r.register(Command(
            id: "tutor.wrap", title: "Wrap up: say each principle plainly, and record my last answer", scope: .session, budget: .slowIO,
            leader: LocalKey(",q"), label: "wrap up", v1: ["click:ask for the consolidation: each "],
            available: { [weak t] _ in t?.active != nil && idle() },
            local: { [weak t] _, _ in
                guard let t, let s = t.active else { return }
                t.answer(s.id, "Let's stop here. Consolidate: say each principle we reached plainly, and record evidence for my last answer.")
            }))
        r.register(Command(
            id: "tutor.stop", title: "Stop the tutor's turn", scope: .session, leader: LocalKey(",s"), label: "stop", v1: ["click:■ stop"],
            available: { [weak t] _ in t?.active?.pendingTurn != nil },
            write: { [weak t] _, _ in
                guard let turn = t?.active?.pendingTurn else { return nil }
                return Write(path: "/tutor-stop", body: ["turn": .string(turn)], settled: { true }, failed: "the turn didn't stop")
            }))

        // ── the session's page ──

        r.register(Command(
            id: "tutor.write", title: "Write: the answer box, or what to dig into", scope: .tutor, verb: .write, label: "write",
            local: { [weak t, weak app] _, _ in
                guard let t, let app else { return }
                if t.learn == nil && t.learnErr.isEmpty { throw Refusal("nothing to write in") }
                if t.drawer != nil { app.beginInsert(insertField.question) }
                else if t.active != nil { app.beginInsert(insertField.draft) }
                else if t.activeID == nil { app.beginInsert(insertField.target) }
                else { throw Refusal("nothing to write in") }
            }))
        r.register(Command(
            id: "tutor.evidence", title: "Show what this session recorded about you", scope: .session, leader: LocalKey(",v"), label: "evidence",
            v1: ["click:what this session has recorded a"],
            local: { [weak t, weak app] _, _ in
                guard let t else { return }
                t.evidenceOpen.toggle()
                if t.evidenceOpen { app?.focus(pane: TutorPane.credits) }
            }))
        r.register(Command(
            id: "tutor.map", title: "Show the topic's map", scope: .session, verb: .map, label: "map",
            local: { [weak t] _, _ in t?.mapOpen.toggle() }))
        r.register(Command(
            id: "tutor.rungs", title: "Show the earlier rungs", scope: .session,
            local: { [weak t] _, _ in t?.historyOpen.toggle() }))
        r.register(Command(
            id: "tutor.rung", title: "Open an earlier rung", scope: .session, needsArg: true, quiet: true,
            local: { [weak t] _, n in
                guard let t, let n = (n as? String).flatMap(Int.init) ?? (n as? Int) else { return }
                t.expanded = t.expanded == n ? nil : n
            }))
        r.register(Command(
            id: "tutor.pin", title: "Show code in the code pane", scope: .tutor, needsArg: true, quiet: true,
            local: { [weak t] _, pin in
                guard let p = pin as? Pin else { throw Refusal("no code to show") }
                t?.showPin(p)
            }))
        r.register(Command(
            id: "tutor.option", title: "Put a suggested answer in the box", scope: .session, needsArg: true, quiet: true,
            local: { [weak t, weak app] _, o in
                guard let t, let o else { return }
                t.draft = String(describing: o)
                app?.beginInsert(insertField.draft)
            }))
        r.register(Command(
            id: "tutor.confidence", title: "Rate how sure you are", scope: .session, needsArg: true, quiet: true,
            available: { c in c != nil && Lesson.confidences.contains(c!) },
            local: { [weak t] c, _ in
                guard let t else { return }
                t.confidence = t.confidence == c ? nil : c
            }))
        for (n, c) in Lesson.confidences.enumerated() {
            r.register(Command(
                id: "tutor.confidence.\(c)", title: "Rate how sure you are: \(c)", scope: .session, verb: .nth(n + 1),
                label: c, quiet: true,
                available: { [weak t] _ in t?.active != nil },
                route: { _ in RouteTo("tutor.confidence", target: c) }))
        }
        r.register(Command(
            id: "tutor.due.all", title: "Show everything that's due", scope: .tutor,
            local: { [weak t] _, _ in t?.allDue.toggle() }))

        // ── sessions you keep (this app only) ──

        let forgetArm = { (id: String) in "forget \(id)" }
        r.register(Command(
            id: "tutor.forget", title: "Forget the session (its evidence stays in the graph)", scope: .lesson, verb: .putAway, label: "forget",
            available: kept,
            route: { [weak t] id in
                guard let t, let id, kept(id) else { return nil }
                return RouteTo(t.armed == forgetArm(id) ? "tutor.forget.confirm" : "tutor.forget.arm", target: id)
            }))
        r.register(Command(
            id: "tutor.forget.arm", title: "Ready forgetting a session (the next press does it)", scope: .lesson, needsArg: true, quiet: true,
            local: { [weak t] id, _ in t?.armed = id.map(forgetArm) }))
        r.register(Command(
            id: "tutor.forget.confirm", title: "Forget a session", scope: .lesson, needsArg: true, v1: ["click:forget this session (its evidenc"], quiet: true,
            local: { [weak t] id, _ in
                t?.armed = nil
                if let id { t?.forget(id) }
            }))
        r.register(Command(
            id: "tutor.pickup", title: "Pick up a terminal session here, as a copy", scope: .pickup, budget: .slowIO, quiet: true,
            local: { [weak t] session, _ in
                guard let t, let session else { return }
                Task { @MainActor in
                    do { try await t.pickUp(session) } catch { t.error = String(describing: error) }
                }
            }))

        // ── the graph's writes ──

        func question(_ op: String, _ id: String) -> Write? {
            guard t.learn?.questions.contains(where: { $0.id == id }) == true else { return nil }
            return Write(
                path: "/learning-question", body: ["op": .string(op), "id": .string(id)], settled: { true },
                said: op == "close" ? "answered · u undoes" : "reopened",
                failed: "couldn't \(op == "close" ? "close" : "reopen") the question",
                inverse: { _ in Inverse(id: op == "close" ? "tutor.question.reopen" : "tutor.question.close", target: id) },
                answered: { [weak t] _, _ in t?.refresh() })
        }
        r.register(Command(id: "tutor.question.close", title: "Mark the question answered", scope: .question, budget: .configWrite, v1: ["click:answered"], quiet: true,
                           write: { id, _ in question("close", id) }))
        r.register(Command(id: "tutor.question.reopen", title: "Reopen the question", scope: .question, budget: .configWrite, v1: ["click:reopen"], quiet: true,
                           write: { id, _ in question("reopen", id) }))
        r.register(Command(
            id: "tutor.question.toggle", title: "Mark the question answered, or reopen it", scope: .question, verb: .mark, label: "answered",
            route: { [weak t] id in
                guard let q = t?.learn?.questions.first(where: { $0.id == id }) else { return nil }
                return RouteTo(q.status == "open" ? "tutor.question.close" : "tutor.question.reopen", target: q.id)
            }))

        /// A question of your own about the concept in the drawer: kept open on the graph, then
        /// asked in the session you're in, or a new one on it.
        r.register(Command(
            id: "tutor.ask", title: "Ask the tutor about the concept", scope: .concept, budget: .configWrite, v1: ["click:ask"], quiet: true,
            available: { [weak t] id in known(id) && !(t?.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) },
            write: { [weak t, weak app] id, _ in
                guard let t, let c = t.concept(id) else { return nil }
                let text = t.question.trimmingCharacters(in: .whitespacesAndNewlines)
                let topic = c.topics.first ?? t.active?.topic ?? ""
                return Write(
                    path: "/learning-question",
                    body: ["op": "add", "text": .string(text), "concept": .string(c.id), "topic": .string(topic)],
                    settled: { true }, failed: "the question wasn't kept",
                    answered: { [weak t, weak app] ok, _ in
                        guard ok, let t else { return }
                        t.question = ""
                        t.refresh()
                        if app?.keys.mode == .insert { app?.keys.setMode(.normal) }
                        let msg = "Question about \(c.name) [\(c.id)]: \(text)"
                        if let s = t.active, !t.streaming {
                            t.closeDrawer()
                            t.answer(s.id, msg)
                        } else {
                            t.start(msg, topic: c.topics.first)
                        }
                    },
                    silent: true)
            }))

        let evidence = { [weak t] (id: String) in t?.learn?.evidence.first { $0.id == id } }
        r.register(Command(
            id: "tutor.evidence.edit", title: "Correct a credit", scope: .credit, budget: .configWrite, needsArg: true, v1: ["click:toggle hit / miss"], quiet: true,
            write: { [weak t] id, arg in
                guard let e = evidence(id), let fields = arg as? [String: String], !fields.isEmpty else { return nil }
                let was = Dictionary(uniqueKeysWithValues: fields.keys.map { ($0, e.field($0)) })
                return Write(
                    path: "/learning-evidence", body: ["op": "edit", "id": .string(id), "fields": .object(fields.mapValues(JSONValue.string))],
                    settled: { true }, said: "corrected · u undoes", failed: "the credit didn't change",
                    inverse: { _ in Inverse(id: "tutor.evidence.edit", target: id, arg: was) },
                    answered: { [weak t] _, _ in t?.refresh() })
            }))
        /// The credit's own controls, by key: hit/miss, then cycling level, credit and confidence.
        func cycle(_ list: [String], _ now: String) -> String { list[((list.firstIndex(of: now) ?? -1) + 1) % list.count] }
        let edits: [(id: String, title: String, key: LocalKey, label: String, fields: (Evidence) -> [String: String])] = [
            ("tutor.evidence.outcome", "Toggle the credit's hit / miss", LocalKey(",o"), "hit/miss", { ["outcome": $0.outcome == "hit" ? "miss" : "hit"] }),
            ("tutor.evidence.level", "Change the credit's level (predict → explain → transfer → critique)", LocalKey(",l"), "level", { ["level": cycle(Lesson.levels, $0.level)] }),
            ("tutor.evidence.credit", "Change the credit's help (unaided → scaffolded → handed)", LocalKey(",h"), "credit", { ["credit": cycle(Lesson.credits, $0.credit)] }),
            ("tutor.evidence.confidence", "Change the credit's confidence rating (none → low → medium → high)", LocalKey(",c"), "confidence",
             { ["confidence": cycle([""] + Lesson.confidences, $0.confidence ?? "")] }),
        ]
        for x in edits {
            r.register(Command(
                id: x.id, title: x.title, scope: .credit, budget: .configWrite, leader: x.key, label: x.label,
                available: { id in id.flatMap(evidence) != nil },
                route: { id in id.flatMap(evidence).map { RouteTo("tutor.evidence.edit", target: $0.id, arg: x.fields($0)) } }))
        }
        let cutArm = { (id: String) in "cut \(id)" }
        r.register(Command(
            id: "tutor.evidence.cut", title: "Cut a credit", scope: .credit, verb: .putAway, label: "cut",
            available: { id in id.flatMap(evidence) != nil },
            route: { [weak t] id in
                guard let t, let id, evidence(id) != nil else { return nil }
                return RouteTo(t.armed == cutArm(id) ? "tutor.evidence.delete" : "tutor.evidence.arm", target: id)
            }))
        r.register(Command(
            id: "tutor.evidence.arm", title: "Ready cutting a credit (the next press does it)", scope: .credit, needsArg: true, quiet: true,
            local: { [weak t] id, _ in t?.armed = id.map(cutArm) }))
        r.register(Command(
            id: "tutor.evidence.delete", title: "Cut a credit", scope: .credit, budget: .configWrite, needsArg: true, v1: ["click:cut this evidence"], quiet: true,
            write: { [weak t] id, _ in
                t?.armed = nil
                guard evidence(id) != nil else { return nil }
                return Write(path: "/learning-evidence", body: ["op": "delete", "id": .string(id)], settled: { true }, said: "cut",
                             failed: "the credit wasn't cut", answered: { [weak t] _, _ in t?.refresh() })
            }))

        // ── types in the code pane: the pinned file is one commit (its ref, else the checkout's HEAD) ──

        let source: () -> CodeLookup.Where? = { [weak t] in
            guard let t, let p = t.pin, !p.path.hasPrefix("/"), let c = t.code, c.err == nil else { return nil }
            return .commit(repo: "", sha: (p.ref ?? "").isEmpty ? "HEAD" : p.ref!)
        }
        let position: () -> CodeLookup.Position? = { [weak t, weak app] in
            guard let t, let app, let p = t.pin, let text = t.code?.text, let line = TutorRows.codeCursor(app, t) else { return nil }
            let lines = TutorRows.lines(text)
            guard lines.indices.contains(line - 1) else { return nil }
            return CodeLookup.position(path: p.path, line: line, text: lines[line - 1])
        }
        let look = CodeLookup.of(app)
        let typed: (String?) -> Bool = { _ in source() != nil }
        r.register(Command(id: "tutor.types", title: "Show the type on the code pane's cursor line (hover)", scope: .tutor, verb: .type, label: "type",
                           available: typed, local: { _, _ in if let s = source() { look.hover(position(), s) } }))
        let gotos: [(String, LSPGoto, Verb, String, String)] = [
            ("tutor.definition", .definition, .definition, "def", "Go to the definition — the code pane follows it"),
            ("tutor.type-definition", .typeDefinition, .typeDefinition, "type def", "Go to the definition of its type"),
            ("tutor.implementation", .implementation, .implementations, "impl", "Go to its implementations"),
            ("tutor.references", .references, .references, "refs", "List its references"),
        ]
        for (id, kind, verb, label, title) in gotos {
            r.register(Command(id: id, title: title, scope: .tutor, verb: verb, label: label, available: typed,
                               local: { _, _ in if let s = source() { look.goto(kind, position(), s) } }))
        }
        r.register(Command(id: "tutor.symbols", title: "List the pinned file's symbols", scope: .tutor, verb: .symbols, label: "symbols",
                           available: typed, local: { [weak t] _, _ in if let t, let s = source(), let p = t.pin { look.symbols(path: p.path, s) } }))
    }
}
