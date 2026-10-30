import CanopyCore
import SwiftUI

/// The tutor (/v2/tutor[/<session>]) — the `tutor` skill around the learner's concept graph
/// (Tutor.tsx, tutoring.ts, lesson.ts, TutorSim.tsx, sim.ts, simScenarios.ts, commands/tutor.ts).
///
///   home     what's due, the topics, open questions, the sessions this app keeps, terminal sessions to pick up
///   session  the topic's map ("you are here") · the current rung (earlier ones fold) · pinned code
///   drawer   one concept: its depth and the evidence behind it (each credit correctable), links, questions
///
/// Mouseless: everything v2 drew as a button is a row in a pane — the map's concepts, a turn's
/// pins, options and concept links, the drawer's links, code, questions and credits — and `ret`
/// runs its main action (`primary`), the way v2's click did.
enum TutorArea: PageArea {
    static let name = "tutor"

    static func install(_ app: AppModel) {
        let t = app.state { TutorState(app: app) }
        app.addSurface(TutorSurface())
        app.registry.addScopes([.credit, .question, .topic, .pickup], to: "tutor")
        TutorCommands.install(app, t)
    }

    /// The tutor's state, made once per window.
    @MainActor static func state(_ app: AppModel) -> TutorState { app.state { TutorState(app: app) } }

    /// The code pane is the jumplist's surface while the tutor is on screen (Tutor.tsx nav.attach).
    @MainActor static func attachNav(_ app: AppModel) -> () -> Void {
        let t = state(app)
        return app.nav.attach(.init(
            open: { [weak t] l in t?.showPin(Pin(path: l.path, ref: l.sha, lines: [l.line, max(l.line, l.end ?? l.line)])) },
            here: { [weak t, weak app] in
                guard let t, let p = t.pin else { return nil }
                let line = app.flatMap { TutorRows.codeCursor($0, t) } ?? p.lit?.0 ?? 1
                return Loc(repo: "", sha: (p.ref ?? "").isEmpty ? "HEAD" : p.ref!, path: p.path, line: line, end: p.lit?.1)
            }))
    }
}

extension Scope {
    /// a credit (one piece of evidence) under the cursor, in the session's audit or the drawer
    static let credit: Scope = "credit"
    /// an open question under the cursor
    static let question: Scope = "question"
    /// a topic under the cursor on the home page
    static let topic: Scope = "topic"
    /// a terminal session to pick up, under the cursor
    static let pickup: Scope = "pickup"
}

/// The tutor's panes.
enum TutorPane {
    static let due = "due", topics = "topics", questions = "questions", sessions = "sessions", pickup = "pickup"
    static let map = "map", credits = "credits", turn = "turn", code = "code", drawer = "drawer"
}

/// What a turn draws as something to act on: code to pin, an answer to pick, a concept to open.
enum TurnItem: Equatable {
    case pin(Pin)
    case option(String)
    case concept(String)
}

/// Row keys and what each one is (model.ts ckey/skey, extended to every v2 button).
///
///   c:<concept>            a concept (due, the session's map)
///   tp:<topic>             a topic       tc:<topic>|<concept>   a concept in a topic's stages
///   q:<question>           a question    s:<session>            a session you keep
///   tm:<session>           a terminal session to pick up
///   e:<evidence>           a credit      L:<line>               a line of pinned code
///   hist                   the earlier rungs' fold     r:<tutorIdx>     an earlier rung
///   x:<msg>:<seg>:<sub>    an item of a turn (pin, option, concept link)
///   dh:<concept>           the drawer's concept        dl:<n>:<concept>  a link in the drawer
///   dc:<n>                 a code ref in the drawer    ask              the drawer's question box
@MainActor
enum TutorRows {
    static func id(_ key: String?, _ prefix: String) -> String? { RowKey.id(key, prefix) }

    // ── home ──

    static func due(_ t: TutorState) -> [String] { t.shownDue.map(RowKey.concept) }

    static func topics(_ t: TutorState) -> [String] {
        t.topicsByUpdate.flatMap { tp in ["tp:\(tp.id)"] + tp.stages.flatMap { $0.concepts.map { "tc:\(tp.id)|\($0)" } } }
    }

    static func questions(_ t: TutorState) -> [String] { t.openQuestions.map { "q:\($0.id)" } }
    static func sessions(_ t: TutorState) -> [String] { t.recent.map { RowKey.lesson($0.id) } }
    static func pickup(_ t: TutorState) -> [String] { t.pickable.map { "tm:\($0.session)" } }

    // ── a session ──

    static func map(_ t: TutorState, _ s: Session) -> [String] {
        guard let topic = s.topic, let tp = t.learn?.topics[topic] else { return [] }
        return tp.stages.flatMap { $0.concepts.map(RowKey.concept) }
    }

    static func mine(_ t: TutorState, _ s: Session) -> [Evidence] { (t.learn?.evidence ?? []).filter { $0.session == s.id } }

    static func credits(_ t: TutorState, _ s: Session) -> [String] { t.evidenceOpen ? mine(t, s).map { "e:\($0.id)" } : [] }

    /// A turn's items, keyed by message and segment; options act only on the newest turn.
    static func items(_ msgIdx: Int, _ text: String, latest: Bool) -> [(key: String, item: TurnItem)] {
        var out: [(String, TurnItem)] = []
        for (i, seg) in Lesson.segments(text).enumerated() {
            let k = "x:\(msgIdx):\(i)"
            switch seg {
            case .pin(let p): out.append(("\(k):0", .pin(p)))
            case .options(let os) where latest: out += os.enumerated().map { ("\(k):\($0.offset)", .option($0.element)) }
            case .rung(let c, _, _, _, _, _): out.append(("\(k):0", .concept(c)))
            case .evidence(let es): out += es.enumerated().map { ("\(k):\($0.offset)", .concept($0.element.concept)) }
            case .restate(let c, _) where !c.isEmpty: out.append(("\(k):0", .concept(c)))
            default: break
            }
        }
        return out
    }

    static func turnItems(_ t: TutorState, _ s: Session) -> [(key: String, item: TurnItem)] {
        let rungs = Lesson.rungsOf(s.msgs)
        var out: [(String, TurnItem)] = []
        for r in rungs.dropLast() where t.historyOpen && t.expanded == r.tutorIdx { out += items(r.tutorIdx, s.msgs[r.tutorIdx].text, latest: false) }
        if let cur = rungs.last { out += items(cur.tutorIdx, s.msgs[cur.tutorIdx].text, latest: true) }
        return out
    }

    static func turn(_ t: TutorState, _ s: Session) -> [String] {
        let rungs = Lesson.rungsOf(s.msgs)
        let earlier = rungs.dropLast()
        var out: [String] = earlier.isEmpty ? [] : ["hist"]
        if t.historyOpen {
            for r in earlier {
                out.append("r:\(r.tutorIdx)")
                if t.expanded == r.tutorIdx { out += items(r.tutorIdx, s.msgs[r.tutorIdx].text, latest: false).map(\.key) }
            }
        }
        if let cur = rungs.last { out += items(cur.tutorIdx, s.msgs[cur.tutorIdx].text, latest: true).map(\.key) }
        return out
    }

    static func codeLines(_ t: TutorState) -> [String] {
        guard t.pin != nil, let c = t.code, c.err == nil, let text = c.text else { return [] }
        return lines(text).indices.map { "s:\($0 + 1)" }
    }

    static func lines(_ text: String) -> [String] {
        var s = text
        if s.hasSuffix("\n") { s.removeLast() }
        return s.components(separatedBy: "\n")
    }

    /// The code pane's cursor line, whichever pane has focus.
    static func codeCursor(_ app: AppModel, _ t: TutorState) -> Int? {
        let rows = codeLines(t)
        guard !rows.isEmpty else { return nil }
        let key = "tutor/\(TutorPane.code)"
        if let c = app.cursors[key], rows.contains(c) { return Int(c.dropFirst(2)) }
        let i = max(0, min(app.cursorIdxs[key] ?? 0, rows.count - 1))
        return Int(rows[i].dropFirst(2))
    }

    // ── the drawer ──

    struct Link { var key: String; var label: String; var id: String }

    static func links(_ t: TutorState, _ c: Concept) -> [(label: String, ids: [String])] {
        let blocked = c.blocked_by ?? []
        return [("needs first — never shown unaided", blocked),
                ("builds on", c.builds_on.filter { !blocked.contains($0) }),
                ("what builds on it", c.built_on_by),
                ("same idea elsewhere", c.analogs)].filter { !$0.1.isEmpty }
    }

    static func drawerEvidence(_ t: TutorState, _ id: String) -> [Evidence] { (t.learn?.evidence ?? []).filter { $0.concept == id }.reversed() }
    static func drawerQuestions(_ t: TutorState, _ id: String) -> [Question] { (t.learn?.questions ?? []).filter { $0.concept == id } }

    static func drawer(_ t: TutorState) -> [String] {
        guard let id = t.drawer else { return [] }
        guard let c = t.concept(id) else { return ["dh:\(id)"] }
        var out = ["dh:\(id)"]
        var n = 0
        for g in links(t, c) { for l in g.ids { out.append("dl:\(n):\(l)"); n += 1 } }
        out += c.code.indices.map { "dc:\($0)" }
        out += drawerQuestions(t, id).map { "q:\($0.id)" }
        out.append("ask")
        out += drawerEvidence(t, id).map { "e:\($0.id)" }
        return out
    }

    // ── what a row is ──

    /// The concept a row is (or names), for the `concept` scope's target.
    static func conceptOf(_ row: String?, _ t: TutorState) -> String? {
        guard let row else { return nil }
        if let c = id(row, "c") ?? id(row, "dh") { return c }
        if let rest = id(row, "tc"), let bar = rest.firstIndex(of: "|") { return String(rest[rest.index(after: bar)...]) }
        if let rest = id(row, "dl"), let colon = rest.firstIndex(of: ":") { return String(rest[rest.index(after: colon)...]) }
        if row.hasPrefix("x:"), case .concept(let c)? = item(row, t) { return c }
        return nil
    }

    static func item(_ row: String, _ t: TutorState) -> TurnItem? {
        guard let s = t.active else { return nil }
        return turnItems(t, s).first { $0.key == row }?.item
    }

    static func pinOf(_ code: ConceptCode) -> Pin {
        Pin(path: code.path, ref: code.ref, lines: code.lines.flatMap { $0.isEmpty ? nil : [$0[0], $0.count > 1 ? $0[1] : $0[0]] })
    }
}

struct TutorSurface: SurfaceProvider {
    let surfaceID = "tutor"

    func view(_ app: AppModel, route: Route) -> AnyView { AnyView(TutorPage()) }

    func panes(_ app: AppModel) -> [Pane] {
        let t = TutorArea.state(app)
        var out: [Pane] = []
        if let s = t.active {
            // the turn first: it's where a session's focus starts
            out.append(Pane(id: TutorPane.turn, title: "turn", rows: TutorRows.turn(t, s), column: 1, row: 1))
            if t.mapOpen { out.append(Pane(id: TutorPane.map, title: "map", rows: TutorRows.map(t, s), column: 0)) }
            let credits = TutorRows.credits(t, s)
            if !credits.isEmpty { out.append(Pane(id: TutorPane.credits, title: "recorded", rows: credits, column: 1, row: 0)) }
            let code = TutorRows.codeLines(t)
            if !code.isEmpty { out.append(Pane(id: TutorPane.code, title: "code", rows: code, column: 2, pageSize: 20)) }
            if t.drawer != nil { out.append(Pane(id: TutorPane.drawer, title: "concept", rows: TutorRows.drawer(t), column: 3)) }
            return out.filter { !$0.rows.isEmpty || $0.id == TutorPane.turn }
        }
        out.append(Pane(id: TutorPane.due, title: "due", rows: TutorRows.due(t), column: 0, row: 0))
        out.append(Pane(id: TutorPane.topics, title: "topics", rows: TutorRows.topics(t), column: 0, row: 1))
        out.append(Pane(id: TutorPane.questions, title: "questions", rows: TutorRows.questions(t), column: 1, row: 0))
        out.append(Pane(id: TutorPane.sessions, title: "sessions", rows: TutorRows.sessions(t), column: 1, row: 1))
        out.append(Pane(id: TutorPane.pickup, title: "terminal", rows: TutorRows.pickup(t), column: 1, row: 2))
        if t.drawer != nil { out.append(Pane(id: TutorPane.drawer, title: "concept", rows: TutorRows.drawer(t), column: 2)) }
        let shown = out.filter { !$0.rows.isEmpty }
        return shown.isEmpty ? [out[0]] : shown
    }

    func scopes(_ app: AppModel) -> [Scope] {
        let t = TutorArea.state(app)
        let sel = app.selected
        var out: [Scope] = []
        if RowKey.id(sel, "e") != nil { out.append(.credit) }
        if RowKey.id(sel, "q") != nil { out.append(.question) }
        if RowKey.id(sel, "tp") != nil { out.append(.topic) }
        if RowKey.id(sel, "tm") != nil { out.append(.pickup) }
        if RowKey.id(sel, "s") != nil { out.append(.lesson) }
        if target(for: .concept, app) != nil { out.append(.concept) }
        if t.activeID != nil { out.append(.session) }
        return out
    }

    func target(for scope: Scope, _ app: AppModel) -> String? {
        let t = TutorArea.state(app)
        let sel = app.selected
        switch scope {
        case .concept: return TutorRows.conceptOf(sel, t) ?? t.drawer
        case .lesson: return RowKey.id(sel, "s")
        case .session: return t.activeID
        case .credit: return RowKey.id(sel, "e")
        case .question: return RowKey.id(sel, "q")
        case .topic: return RowKey.id(sel, "tp")
        case .pickup: return RowKey.id(sel, "tm")
        default: return nil
        }
    }

    /// What `ret` does on a row: what v2's click on it did.
    func primary(for row: String, _ app: AppModel) -> RouteTo? {
        let t = TutorArea.state(app)
        if let c = TutorRows.conceptOf(row, t) { return RouteTo("tutor.concept.show", target: c) }
        if let x = RowKey.id(row, "tp") { return RouteTo("tutor.topic", target: x) }
        if let x = RowKey.id(row, "q") { return RouteTo("tutor.pursue", target: x) }
        if let x = RowKey.id(row, "s") { return RouteTo("tutor.open", target: x) }
        if let x = RowKey.id(row, "tm") { return RouteTo("tutor.pickup", target: x) }
        if let x = RowKey.id(row, "e"), let e = t.learn?.evidence.first(where: { $0.id == x }) { return RouteTo("tutor.concept.show", target: e.concept) }
        if let n = RowKey.id(row, "dc").flatMap(Int.init), t.active != nil, let c = t.concept(t.drawer), c.code.indices.contains(n) {
            return RouteTo("tutor.pin", arg: TutorRows.pinOf(c.code[n]))
        }
        if row == "ask" { return RouteTo("tutor.write") }
        if row == "hist" { return RouteTo("tutor.rungs") }
        if let n = RowKey.id(row, "r") { return RouteTo("tutor.rung", arg: n) }
        if row.hasPrefix("x:"), let item = TutorRows.item(row, t) {
            switch item {
            case .pin(let p): return RouteTo("tutor.pin", arg: p)
            case .option(let o): return RouteTo("tutor.option", arg: o)
            case .concept(let c): return RouteTo("tutor.concept.show", target: c)
            }
        }
        return nil
    }
}
