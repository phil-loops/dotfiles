import CanopyCore
import SwiftUI

// Tutor.tsx: the home (what's due, the topics, open questions, sessions, terminal sessions), a
// session (map · current rung · pinned code), and the concept drawer. Every actionable thing is a
// row in a pane: the focused pane wears a ring, its cursor row is lit, and the cursor is kept on
// screen. Keys do everything; a click on a row only moves the cursor there.

struct TutorPage: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @State private var detach: (() -> Void)?

    var body: some View {
        let t = TutorArea.state(app)
        Group {
            if t.learn == nil && t.learnErr.isEmpty {
                Text("reading your graph…").foregroundStyle(theme.inkFaint).padding(.horizontal, 16)
            } else if let s = t.active {
                TutorSessionView(s: s)
            } else if t.activeID != nil {
                Text("no such session in this app").foregroundStyle(theme.inkFaint).padding(.horizontal, 16)
            } else {
                TutorHome()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(alignment: .trailing) {
            if t.drawer != nil { TutorDrawer().frame(width: 460).frame(maxHeight: .infinity) }
        }
        .onAppear {
            detach = TutorArea.attachNav(app)
            t.refresh()
            t.reattach()
        }
        .onDisappear { detach?(); detach = nil }
    }
}

// ── shared bits ──────────────────────────────────────────────────────────

/// The label style v2 uses for small caps headers.
struct TutorLabel: View {
    @Environment(\.theme) private var theme
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text.uppercased()).font(Theme.mono(10)).tracking(1.4).foregroundStyle(theme.inkFaint) }
}

/// A key the way the hint lines show it (Key.tsx).
struct TutorKey: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    let id: String
    var body: some View {
        if let k = app.registry.command(id)?.keys.first {
            Text(glyph(k)).font(Theme.mono(10)).foregroundStyle(theme.goldDeep)
                .padding(.horizontal, 3).overlay(RoundedRectangle(cornerRadius: 2).stroke(theme.rule))
        }
    }
}

/// A concept's depth: four pips (predict · explain · transfer · critique), and a red dot for an open miss.
struct Pips: View {
    @Environment(\.theme) private var theme
    let m: Mastery?
    var size: CGFloat = 7

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<Lesson.levels.count, id: \.self) { i in
                let held = (m?.held ?? 0) > i, shown = (m?.depth ?? 0) > i, helped = (m?.assisted ?? 0) > i
                RoundedRectangle(cornerRadius: 1)
                    .fill(held ? theme.goldLeaf : shown ? theme.goldLeaf.opacity(0.25) : .clear)
                    .overlay(RoundedRectangle(cornerRadius: 1).stroke(held || shown ? theme.goldLeaf : helped ? theme.goldDeep : theme.rule, lineWidth: 1))
                    .frame(width: size, height: size)
            }
            if let m, !m.open_miss.isEmpty {
                Circle().fill(theme.del).frame(width: 5, height: 5).padding(.leading, 3)
                    .overlay(Circle().stroke(theme.del.opacity(0.4), lineWidth: m.miss_confidence == "high" ? 2 : 0).padding(.leading, 3))
            }
        }
        .help(m.map(Lesson.pipsTitle) ?? "")
    }
}

/// One row of a pane: lit when it's the cursor of the focused pane, washed when the focused pane's
/// select range holds it, and tagged so the page's scroll view can follow the cursor to it.
struct TutorRow<Content: View>: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    let pane: String
    let key: String
    @ViewBuilder let content: (_ on: Bool) -> Content

    var body: some View {
        let focused = app.isFocused(pane)
        let on = focused && app.selected == key
        let inRange = focused && app.selection.count > 1 && app.selection.contains(key)
        content(on)
            .padding(.vertical, 3).padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(on ? theme.goldWash : inRange ? theme.emberWash : .clear)
            .overlay(alignment: .leading) { if on { theme.goldLeaf.frame(width: 2) } }
            .contentShape(Rectangle())
            .onTapGesture {
                app.focus(pane: pane)
                app.setCursor(key)
            }
            .id(TutorScroll.id(pane, key))
    }
}

/// A pane's frame: a ring while it has focus.
struct TutorPaneFrame: ViewModifier {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    let pane: String
    func body(content: Content) -> some View {
        content.overlay { Rectangle().stroke(app.isFocused(pane) ? theme.goldDeep : .clear, lineWidth: 1) }
    }
}

extension View {
    func tutorPane(_ id: String) -> some View { modifier(TutorPaneFrame(pane: id)) }
}

enum TutorScroll {
    static func id(_ pane: String, _ key: String) -> String { "\(pane)/\(key)" }
}

/// Keeps the cursor on screen for the panes drawn inside one scroll view.
struct FollowCursor: ViewModifier {
    @Environment(AppModel.self) private var app
    let panes: Set<String>
    let proxy: ScrollViewProxy
    func body(content: Content) -> some View {
        content.onChange(of: "\(app.pane?.id ?? "")/\(app.selected ?? "")") { _, _ in
            guard let p = app.pane?.id, panes.contains(p), let k = app.selected else { return }
            withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(TutorScroll.id(p, k)) }
        }
    }
}

/// A concept as a chip: its pips and its name.
struct ConceptChip: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    let id: String
    var here = false
    var on = false

    var body: some View {
        let t = TutorArea.state(app)
        let c = t.concept(id)
        HStack(spacing: 6) {
            Pips(m: c?.mastery)
            Text(t.nameOf(id)).foregroundStyle(here || on ? theme.ink : theme.inkDim).lineLimit(2)
            if let b = c?.blocked_by, !b.isEmpty {
                Text("⊘").font(Theme.mono(11)).foregroundStyle(theme.inkFaint)
            }
        }
        .font(Theme.mono(12))
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(here ? theme.goldWash : .clear)
        .overlay(RoundedRectangle(cornerRadius: 1).stroke(here ? theme.goldLeaf : on ? theme.inkFaint : theme.rule))
    }
}

/// The tutor's prose, through the one markdown renderer.
struct TutorProse: View {
    let text: String
    var size: CGFloat = 14.5

    var body: some View { MarkdownView(text, size: size) }
}

// ── home ─────────────────────────────────────────────────────────────────

struct TutorHome: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        @Bindable var t = TutorArea.state(app)
        ScrollViewReader { proxy in
            ScrollView {
                HStack(alignment: .top, spacing: 40) {
                    VStack(alignment: .leading, spacing: 0) {
                        if let s = t.recent.first { ContinueCard(s: s).padding(.bottom, 28) }
                        Text("What do you want to dig into?").font(Theme.display(26)).foregroundStyle(theme.ink).padding(.bottom, 12)
                        ModalTextField(TutorCommands.insertField.target, prompt: "a PR number, a branch, a file, or a concept", text: $t.target)
                            .font(Theme.mono(14)).padding(.horizontal, 10).padding(.vertical, 7)
                            .background(theme.vellumRaise)
                            .overlay(Rectangle().stroke(app.insertField == TutorCommands.insertField.target ? theme.goldDeep : theme.rule))
                        HStack(spacing: 6) {
                            TutorKey(id: "tutor.write")
                            Text("types here · ↵ starts — the tutor reads the code first").font(Theme.mono(11)).foregroundStyle(theme.inkFaint)
                        }
                        .padding(.top, 6).padding(.bottom, 28)
                        if !(t.error.isEmpty && t.learnErr.isEmpty) {
                            Text(t.error.isEmpty ? t.learnErr : t.error).font(Theme.mono(12)).foregroundStyle(theme.del).padding(.bottom, 20)
                        }
                        DueSection().padding(.bottom, 28)
                        TopicsSection()
                    }
                    .frame(maxWidth: 760, alignment: .leading)
                    VStack(alignment: .leading, spacing: 28) {
                        QuestionsSection()
                        if !t.sessions.isEmpty { SessionsSection() }
                        if !t.pickable.isEmpty { PickupSection() }
                    }
                    .frame(width: 320, alignment: .leading)
                }
                .padding(.horizontal, 28).padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .modifier(FollowCursor(panes: [TutorPane.due, TutorPane.topics, TutorPane.questions, TutorPane.sessions, TutorPane.pickup], proxy: proxy))
        }
        .onAppear { t.listTerminal() }
    }
}

struct ContinueCard: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    let s: Session

    var body: some View {
        let t = TutorArea.state(app)
        let last = s.msgs.reversed().first { $0.role == "tutor" && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let here: String? = { if case .rung(let c, _, _, _, _, _)? = Lesson.latest(s.msgs, .rung) { return c }; return nil }()
        let waiting = s.msgs.last?.role == "tutor"
        VStack(alignment: .leading, spacing: 8) {
            TutorLabel("continue where you left off")
            HStack(alignment: .firstTextBaseline) {
                Text(t.titleOf(s)).font(Theme.display(20)).foregroundStyle(theme.ink).lineLimit(1)
                Spacer()
                Text("rung \(s.msgs.filter { $0.role == "tutor" }.count) · \(Lesson.ago(s.touched))").font(Theme.mono(11)).foregroundStyle(theme.inkFaint)
            }
            if let here { ConceptChip(id: here, here: true) }
            if let last {
                (Text(waiting ? "WAITING ON YOU · " : "LAST QUESTION · ").font(Theme.mono(10)).foregroundColor(theme.inkFaint)
                    + Text(Lesson.questionOf(last.text)).font(.system(size: 15, design: .serif)).foregroundColor(theme.inkDim))
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                Text("continue: the session's row in Sessions, then").font(Theme.mono(11)).foregroundStyle(theme.inkFaint)
                TutorKey(id: "tutor.open")
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 16)
        .background(theme.goldWash)
        .overlay(Rectangle().stroke(theme.goldDeep))
    }
}

struct DueSection: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        let t = TutorArea.state(app)
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("Due").font(Theme.display(19)).foregroundStyle(theme.ink)
                Text("\(t.due.count) concepts").font(Theme.mono(11)).foregroundStyle(theme.inkFaint)
            }
            Text("open misconceptions first, then what you've shown only with help, then whatever's gone longest unchecked")
                .font(Theme.mono(12)).foregroundStyle(theme.inkFaint).padding(.bottom, 6)
            VStack(spacing: 0) {
                ForEach(t.shownDue, id: \.self) { id in
                    TutorRow(pane: TutorPane.due, key: RowKey.concept(id)) { on in
                        let c = t.concept(id)
                        HStack(spacing: 12) {
                            Pips(m: c?.mastery)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(t.nameOf(id)).font(Theme.mono(14)).foregroundStyle(on ? theme.goldLeaf : theme.ink).lineLimit(1)
                                HStack(spacing: 0) {
                                    if c?.mastery.miss_confidence == "high" { Text("confident miss · ").foregroundStyle(theme.del) }
                                    Text(c?.mastery.reason ?? "").foregroundStyle(theme.inkFaint)
                                }
                                .font(Theme.mono(11.5)).lineLimit(1)
                            }
                            Spacer()
                            if on {
                                HStack(spacing: 4) { TutorKey(id: "tutor.retest"); Text("re-test cold") }.font(Theme.mono(11)).foregroundStyle(theme.ember)
                            }
                        }
                    }
                }
            }
            .tutorPane(TutorPane.due)
            if t.due.count > 8 {
                Text(t.allDue ? ":tutor.due.all — fewer" : ":tutor.due.all — all \(t.due.count)").font(Theme.mono(11)).foregroundStyle(theme.inkFaint).padding(.top, 6)
            }
        }
    }
}

struct TopicsSection: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        let t = TutorArea.state(app)
        VStack(alignment: .leading, spacing: 4) {
            Text("Topics").font(Theme.display(19)).foregroundStyle(theme.ink)
            Text("paths through one graph — the same idea met in two topics is one concept, linked as an analog")
                .font(Theme.mono(12)).foregroundStyle(theme.inkFaint).padding(.bottom, 10)
            VStack(alignment: .leading, spacing: 14) {
                ForEach(t.topicsByUpdate, id: \.id) { tp in
                    VStack(alignment: .leading, spacing: 6) {
                        TutorRow(pane: TutorPane.topics, key: "tp:\(tp.id)") { on in
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text(tp.title).font(Theme.display(16)).foregroundStyle(on ? theme.goldLeaf : theme.ink).lineLimit(1)
                                Spacer()
                                Text("\(tp.progress.held) held · \(tp.progress.shown ?? tp.progress.held) shown / \(tp.progress.total)")
                                    .font(Theme.mono(11)).foregroundStyle(theme.inkFaint)
                                if on { Text("↵ continue").font(Theme.mono(11)).foregroundStyle(theme.ember) }
                            }
                        }
                        ProgressBar(held: tp.progress.held, shown: tp.progress.shown ?? tp.progress.held, total: tp.progress.total).padding(.horizontal, 8)
                        ForEach(Array(tp.stages.enumerated()), id: \.offset) { _, st in
                            HStack(alignment: .top, spacing: 12) {
                                Text(st.name).font(Theme.mono(11.5)).foregroundStyle(theme.inkFaint).frame(width: 140, alignment: .leading).padding(.top, 4)
                                VStack(alignment: .leading, spacing: 0) {
                                    ForEach(st.concepts, id: \.self) { id in
                                        TutorRow(pane: TutorPane.topics, key: "tc:\(tp.id)|\(id)") { on in ConceptChip(id: id, on: on) }
                                    }
                                }
                            }
                            .padding(.leading, 8)
                        }
                        if !tp.source.isEmpty { Text(tp.source).font(Theme.mono(10.5)).foregroundStyle(theme.inkFaint).padding(.leading, 8) }
                    }
                    .padding(.vertical, 10)
                    .overlay(Rectangle().stroke(theme.rule))
                }
            }
            .tutorPane(TutorPane.topics)
        }
    }
}

struct ProgressBar: View {
    @Environment(\.theme) private var theme
    let held: Int, shown: Int, total: Int
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                theme.rule
                theme.goldDeep.frame(width: total > 0 ? g.size.width * CGFloat(shown) / CGFloat(total) : 0)
                theme.goldLeaf.frame(width: total > 0 ? g.size.width * CGFloat(held) / CGFloat(total) : 0)
            }
        }
        .frame(height: 3)
    }
}

struct QuestionsSection: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        let t = TutorArea.state(app)
        VStack(alignment: .leading, spacing: 4) {
            Text("Your open questions").font(Theme.display(17)).foregroundStyle(theme.ink)
            if t.openQuestions.isEmpty {
                Text("none open — ask one from any concept").font(Theme.mono(12)).foregroundStyle(theme.inkFaint)
            }
            VStack(spacing: 0) {
                ForEach(t.openQuestions, id: \.id) { q in
                    TutorRow(pane: TutorPane.questions, key: "q:\(q.id)") { on in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(q.text).font(Theme.mono(13)).foregroundStyle(theme.ink).fixedSize(horizontal: false, vertical: true)
                            HStack(spacing: 10) {
                                if !q.concept.isEmpty { Text(t.nameOf(q.concept)).foregroundStyle(theme.inkFaint) }
                                if on {
                                    Text("↵ pursue").foregroundStyle(theme.ember)
                                    HStack(spacing: 3) { TutorKey(id: "tutor.question.toggle"); Text("answered") }.foregroundStyle(theme.inkFaint)
                                }
                            }
                            .font(Theme.mono(11))
                        }
                    }
                }
            }
            .tutorPane(TutorPane.questions)
        }
    }
}

struct SessionsSection: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        let t = TutorArea.state(app)
        VStack(alignment: .leading, spacing: 4) {
            Text("Sessions").font(Theme.display(17)).foregroundStyle(theme.ink)
            VStack(spacing: 0) {
                ForEach(t.recent, id: \.id) { s in
                    TutorRow(pane: TutorPane.sessions, key: RowKey.lesson(s.id)) { on in
                        let arming = t.armed == "forget \(s.id)"
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(t.titleOf(s)).font(Theme.mono(12.5)).foregroundStyle(on ? theme.goldLeaf : theme.inkDim).lineLimit(1)
                            Spacer()
                            Text("\(s.msgs.filter { $0.role == "tutor" }.count) · \(Lesson.ago(s.touched))").font(Theme.mono(10.5)).foregroundStyle(theme.inkFaint)
                            if on {
                                HStack(spacing: 3) { TutorKey(id: "tutor.forget"); Text(arming ? "again forgets it" : "forget") }
                                    .font(Theme.mono(11)).foregroundStyle(arming ? theme.del : theme.inkFaint)
                            }
                        }
                    }
                }
            }
            .tutorPane(TutorPane.sessions)
        }
    }
}

struct PickupSection: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        let t = TutorArea.state(app)
        VStack(alignment: .leading, spacing: 4) {
            Text("Pick up from the terminal").font(Theme.display(17)).foregroundStyle(theme.ink)
            Text("continues here as a copy; the terminal session is left alone").font(Theme.mono(11.5)).foregroundStyle(theme.inkFaint)
            VStack(spacing: 0) {
                ForEach(t.pickable, id: \.session) { s in
                    TutorRow(pane: TutorPane.pickup, key: "tm:\(s.session)") { on in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(s.target.isEmpty ? TutorState.worktreeName(s.cwd) : s.target).font(Theme.mono(13)).foregroundStyle(on ? theme.goldLeaf : theme.ink).lineLimit(1)
                            Text("\(TutorState.worktreeName(s.cwd)) · \(s.answers) answers").font(Theme.mono(11)).foregroundStyle(theme.inkFaint)
                        }
                    }
                }
            }
            .tutorPane(TutorPane.pickup)
        }
    }
}

// ── a session ────────────────────────────────────────────────────────────

struct TutorSessionView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    let s: Session

    var body: some View {
        let t = TutorArea.state(app)
        let rungs = Lesson.rungsOf(s.msgs)
        HStack(alignment: .top, spacing: 0) {
            if t.mapOpen { SessionMap(s: s).frame(width: 240).frame(maxHeight: .infinity) ; theme.rule.frame(width: 1) }
            SessionCenter(s: s).frame(minWidth: 380, maxWidth: t.pin == nil ? 760 : .infinity)
            if t.pin != nil { theme.rule.frame(width: 1); PinnedCode().frame(minWidth: 320, maxWidth: .infinity) }
        }
        .overlay(alignment: .top) { theme.rule.frame(height: 1) }
        .onAppear {
            app.focus(pane: TutorPane.turn)
            t.followNewestPin(s)
            placeHere(t)
        }
        .onChange(of: s.msgs) { _, _ in t.followNewestPin(s) }
        .onChange(of: t.here) { _, _ in placeHere(t) }
        .onChange(of: rungs.last?.tutorIdx) { _, _ in
            t.confidence = nil
            t.askedConfidence = false
        }
        .onChange(of: t.code) { _, _ in placeCodeCursor(t) }
    }

    /// the map's cursor starts on the concept the rung tests
    private func placeHere(_ t: TutorState) {
        if let h = t.here { place(RowKey.concept(h), in: TutorPane.map) }
    }

    /// the code pane's cursor starts on the pin's lines
    private func placeCodeCursor(_ t: TutorState) {
        if let lit = t.pin?.lit, t.code?.text != nil { place("L:\(lit.0)", in: TutorPane.code) }
    }

    private func place(_ key: String, in pane: String) {
        let back = app.pane?.id
        app.focus(pane: pane)
        guard app.pane?.id == pane else { return }
        app.setCursor(key)
        if let back { app.focus(pane: back) }
    }
}

struct SessionMap: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    let s: Session

    var body: some View {
        let t = TutorArea.state(app)
        VStack(alignment: .leading, spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if let topic = s.topic.flatMap({ t.learn?.topics[$0] }) {
                            TutorLabel("map").padding(.bottom, 4)
                            Text(topic.title).font(Theme.display(15)).foregroundStyle(theme.ink).padding(.bottom, 2)
                            Text("\(topic.progress.held) held · \(topic.progress.shown ?? topic.progress.held) shown / \(topic.progress.total)")
                                .font(Theme.mono(10.5)).foregroundStyle(theme.inkFaint).padding(.bottom, 14)
                            ForEach(Array(topic.stages.enumerated()), id: \.offset) { _, st in
                                Text(st.name).font(Theme.mono(11)).foregroundStyle(theme.inkFaint).padding(.bottom, 4)
                                ForEach(st.concepts, id: \.self) { id in
                                    TutorRow(pane: TutorPane.map, key: RowKey.concept(id)) { on in ConceptChip(id: id, here: t.here == id, on: on) }
                                }
                                Spacer().frame(height: 12)
                            }
                        } else {
                            Text("no map yet — the tutor draws one once it has read the material").font(Theme.mono(12)).foregroundStyle(theme.inkFaint)
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                }
                .modifier(FollowCursor(panes: [TutorPane.map], proxy: proxy))
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Pips(m: { var m = Mastery(); m.held = 1; m.depth = 2; m.assisted = 3; return m }())
                    Text("predict · explain · transfer · critique")
                }
                Text("solid held (two days) · faint shown once · outline only with help · red an open misconception · ⊘ needs a prerequisite first")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(Theme.mono(10)).foregroundStyle(theme.inkFaint).padding(12)
        }
        .tutorPane(TutorPane.map)
    }
}

struct SessionCenter: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    let s: Session

    var body: some View {
        @Bindable var t = TutorArea.state(app)
        let rungs = Lesson.rungsOf(s.msgs)
        let current = rungs.last
        let earlier = Array(rungs.dropLast())
        let prevAnswer: String = {
            guard let i = current?.tutorIdx, i > 0, s.msgs[i - 1].role == "me" else { return "" }
            return s.msgs[i - 1].text
        }()
        let mine = TutorRows.mine(t, s)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text(t.titleOf(s)).font(Theme.display(15)).foregroundStyle(theme.ink).lineLimit(1)
                Spacer()
                HStack(spacing: 3) { Text("map"); TutorKey(id: "tutor.map") }.foregroundStyle(t.mapOpen ? theme.goldLeaf : theme.inkFaint)
                HStack(spacing: 3) { Text("evidence · \(mine.count)"); TutorKey(id: "tutor.evidence") }.foregroundStyle(t.evidenceOpen ? theme.goldLeaf : theme.inkFaint)
                HStack(spacing: 3) { Text("wrap up"); TutorKey(id: "tutor.wrap") }.foregroundStyle(t.streaming ? theme.inkFaint.opacity(0.4) : theme.inkFaint)
            }
            .font(Theme.mono(11))
            .padding(.horizontal, 20).padding(.vertical, 8)
            theme.rule.frame(height: 1)

            if t.evidenceOpen {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            TutorLabel("recorded this session — correct or cut anything over-credited").padding(.bottom, 6)
                            if mine.isEmpty { Text("nothing yet — evidence lands after each answer").font(Theme.mono(12)).foregroundStyle(theme.inkFaint) }
                            ForEach(mine, id: \.id) { e in
                                TutorRow(pane: TutorPane.credits, key: "e:\(e.id)") { on in EvidenceRow(e: e, showConcept: true, on: on) }
                            }
                        }
                        .padding(.horizontal, 20).padding(.vertical, 10)
                    }
                    .modifier(FollowCursor(panes: [TutorPane.credits], proxy: proxy))
                }
                .frame(maxHeight: 260)
                .background(theme.vellumRaise)
                .tutorPane(TutorPane.credits)
                theme.rule.frame(height: 1)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if !earlier.isEmpty {
                            TutorRow(pane: TutorPane.turn, key: "hist") { _ in
                                Text("\(t.historyOpen ? "▾" : "▸") \(earlier.count) earlier \(earlier.count == 1 ? "rung" : "rungs")")
                                    .font(Theme.mono(11)).foregroundStyle(theme.inkFaint)
                            }
                            if t.historyOpen {
                                ForEach(earlier, id: \.tutorIdx) { r in
                                    TutorRow(pane: TutorPane.turn, key: "r:\(r.tutorIdx)") { _ in
                                        HStack(alignment: .top, spacing: 8) {
                                            Text("\(r.n)").foregroundStyle(theme.inkFaint).frame(width: 22, alignment: .trailing)
                                            VStack(alignment: .leading, spacing: 1) {
                                                Text(Lesson.askOf(s.msgs[r.tutorIdx].text)).foregroundStyle(theme.inkDim).lineLimit(1)
                                                if let a = r.answer { Text("→ \(Lesson.spoken(a))").foregroundStyle(theme.ink).lineLimit(1) }
                                            }
                                        }
                                        .font(Theme.mono(12.5))
                                    }
                                    if t.expanded == r.tutorIdx {
                                        VStack(alignment: .leading, spacing: 0) {
                                            TurnView(msgIdx: r.tutorIdx, text: s.msgs[r.tutorIdx].text, latest: false)
                                            if let a = r.answer { Said(text: "you: \(a)").font(Theme.mono(12.5)).foregroundStyle(theme.inkDim) }
                                        }
                                        .padding(.leading, 16).overlay(alignment: .leading) { theme.goldDeep.frame(width: 2) }
                                        .padding(.horizontal, 20).padding(.bottom, 10)
                                    }
                                }
                            }
                            theme.rule.frame(height: 1)
                        }
                        VStack(alignment: .leading, spacing: 0) {
                            if !prevAnswer.isEmpty {
                                VStack(alignment: .leading, spacing: 2) {
                                    TutorLabel("you said")
                                    Said(text: prevAnswer).font(Theme.mono(12.5)).foregroundStyle(theme.inkDim)
                                }
                                .padding(.leading, 12).overlay(alignment: .leading) { theme.rule.frame(width: 2) }
                                .padding(.bottom, 16)
                            }
                            if let c = current { TurnView(msgIdx: c.tutorIdx, text: s.msgs[c.tutorIdx].text, latest: true).id("turn-top-\(c.tutorIdx)") }
                            if t.streaming && !t.status.isEmpty {
                                Text("\(t.status)…").font(Theme.mono(11)).foregroundStyle(theme.inkFaint).lineLimit(1)
                            }
                            if let e = s.error { Text(e).font(Theme.mono(12)).foregroundStyle(theme.del).padding(.top, 8) }
                        }
                        .padding(20)
                    }
                }
                .modifier(FollowCursor(panes: [TutorPane.turn], proxy: proxy))
                // a new rung reads from its top — never chase the bottom while it streams
                .onChange(of: current?.tutorIdx) { _, i in if let i { proxy.scrollTo("turn-top-\(i)", anchor: .top) } }
            }
            .tutorPane(TutorPane.turn)

            theme.rule.frame(height: 1)
            AnswerBox(s: s)
        }
    }
}

struct AnswerBox: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    let s: Session

    var body: some View {
        @Bindable var t = TutorArea.state(app)
        let typing = app.insertField == TutorCommands.insertField.draft
        VStack(alignment: .leading, spacing: 6) {
            ModalTextField(TutorCommands.insertField.draft, prompt: t.streaming ? "…" : "your prediction, your why, or your own question", text: $t.draft)
                .font(.system(size: 14.5, design: .serif)).lineLimit(3...8)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(theme.vellumRaise)
                .overlay(Rectangle().stroke(typing ? theme.goldDeep : theme.rule))
            if t.wantsConfidence && !t.streaming {
                HStack(spacing: 8) {
                    Text(t.askedConfidence && t.confidence == nil ? "how sure are you? (↵ again to skip)" : "how sure are you?")
                        .foregroundStyle(t.askedConfidence && t.confidence == nil ? theme.ember : theme.inkFaint)
                    ForEach(Array(Lesson.confidences.enumerated()), id: \.offset) { i, c in
                        HStack(spacing: 3) { TutorKey(id: "tutor.confidence.\(c)"); Text(c) }
                            .padding(.horizontal, 8).padding(.vertical, 2)
                            .foregroundStyle(t.confidence == c ? theme.goldLeaf : theme.inkDim)
                            .background(t.confidence == c ? theme.goldWash : .clear)
                            .overlay(Rectangle().stroke(t.confidence == c ? theme.goldLeaf : theme.rule))
                    }
                }
                .font(Theme.mono(11))
            }
            HStack {
                HStack(spacing: 4) {
                    TutorKey(id: "tutor.write")
                    Text("writes · ↵ sends · ⌥↵ a new line · esc leaves the box")
                }
                Spacer()
                if t.streaming { HStack(spacing: 3) { Text("■ stop"); TutorKey(id: "tutor.stop") } }
            }
            .font(Theme.mono(10.5)).foregroundStyle(theme.inkFaint)
        }
        .padding(16)
    }
}

/// One tutor turn, as prose and the blocks the page draws.
struct TurnView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    let msgIdx: Int
    let text: String
    let latest: Bool

    var body: some View {
        let t = TutorArea.state(app)
        let segs = Lesson.segments(text)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(segs.enumerated()), id: \.offset) { i, seg in
                let k = "x:\(msgIdx):\(i)"
                switch seg {
                case .prose(let p):
                    TutorProse(text: p)
                case .pin(let pin):
                    TutorRow(pane: TutorPane.turn, key: "\(k):0") { on in
                        HStack(spacing: 8) {
                            Text(pin.path).lineLimit(1)
                            if let l = pin.lit { Text("L\(l.0)–\(l.1)").foregroundStyle(theme.inkFaint) }
                            if on { Text("↵ show").foregroundStyle(theme.ember) }
                        }
                        .font(Theme.mono(11)).foregroundStyle(on ? theme.goldLeaf : theme.inkDim)
                        .padding(.horizontal, 6).padding(.vertical, 2).overlay(Rectangle().stroke(theme.rule))
                    }
                case .options(let os):
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(os.enumerated()), id: \.offset) { j, o in
                            if latest {
                                TutorRow(pane: TutorPane.turn, key: "\(k):\(j)") { on in OptionChip(text: o, on: on, enabled: true) }
                            } else {
                                OptionChip(text: o, on: false, enabled: false).padding(.horizontal, 8).padding(.vertical, 3)
                            }
                        }
                    }
                case .rung(let c, let level, let rung, let conf, let via, let contrastOf):
                    TutorRow(pane: TutorPane.turn, key: "\(k):0") { on in
                        HStack(spacing: 8) {
                            Pips(m: t.concept(c)?.mastery)
                            Text("testing \(t.nameOf(c)) · \(level)\(rung == "invent" ? " · invent the rule" : "")\(via.isEmpty ? "" : " · via \(t.nameOf(via))")\(contrastOf.isEmpty ? "" : " · contrast re-test of a miss")\(conf ? " · rate your confidence" : "")")
                        }
                        .font(Theme.mono(10.5)).foregroundStyle(on ? theme.goldLeaf : theme.inkFaint)
                    }
                case .evidence(let items):
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.offset) { j, e in
                            TutorRow(pane: TutorPane.turn, key: "\(k):\(j)") { _ in
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("\(e.outcome == "miss" ? "✗" : "✓") \(t.nameOf(e.concept)) · \(e.level) · \(e.credit)\(e.confidence.isEmpty ? "" : " · \(e.confidence) confidence")\(e.via.isEmpty ? "" : " · via \(t.nameOf(e.via))")")
                                        .foregroundStyle(e.outcome == "miss" ? theme.del : theme.add)
                                    if !e.note.isEmpty { Text("— \(e.note)").foregroundStyle(theme.inkFaint) }
                                    if !e.contrast.isEmpty { Text("re-test with: \(e.contrast)").foregroundStyle(theme.inkFaint) }
                                }
                                .font(Theme.mono(11))
                            }
                        }
                    }
                case .map(let title, let count):
                    Text("map drawn · \(count) concepts in \(title)").font(Theme.mono(10.5)).foregroundStyle(theme.inkFaint)
                case .restate(let c, let said):
                    TutorRow(pane: TutorPane.turn, key: "\(k):0") { _ in
                        (Text("IN YOUR WORDS · \(t.nameOf(c).uppercased()) ").font(Theme.mono(10)).foregroundColor(theme.inkFaint)
                            + Text("“\(said)”").font(Theme.mono(13.5)).foregroundColor(theme.goldLeaf))
                    }
                case .question(let c, let q):
                    Text("? your question, kept open\(c.isEmpty ? "" : " on \(t.nameOf(c))"): \(q)").font(Theme.mono(11)).foregroundStyle(theme.inkFaint)
                case .sim(let scenario, let off):
                    SimFrozen(scenario: scenario, off: off)
                case .simResult(let scenario, let off, _, _):
                    SimPlayed(scenario: scenario, off: off)
                case .quiet:
                    EmptyView()
                }
            }
        }
        .padding(.bottom, 16)
    }
}

struct OptionChip: View {
    @Environment(\.theme) private var theme
    let text: String
    let on: Bool
    let enabled: Bool
    var body: some View {
        HStack(spacing: 8) {
            Text(text).foregroundStyle(theme.ink)
            if on { Text("↵ into the box — then say why").foregroundStyle(theme.ember).font(Theme.mono(11)) }
        }
        .font(Theme.mono(13))
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(theme.goldWash)
        .overlay(Rectangle().stroke(on ? theme.goldLeaf : theme.goldDeep))
        .opacity(enabled ? 1 : 0.4)
    }
}

/// What the learner said: their words, then any sim their answer played.
struct Said: View {
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Lesson.spoken(text)).fixedSize(horizontal: false, vertical: true)
            ForEach(Array(Lesson.segments(text).enumerated()), id: \.offset) { _, x in
                if case .simResult(let scenario, let off, _, _) = x { SimPlayed(scenario: scenario, off: off) }
            }
        }
    }
}

/// A credit: hit/miss, level, credit and confidence — each changeable by key (m, w, f, y) — and its note.
struct EvidenceRow: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    let e: Evidence
    var showConcept = false
    var on = false

    var body: some View {
        let t = TutorArea.state(app)
        let arming = t.armed == "cut \(e.id)"
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(e.outcome == "miss" ? "✗" : "✓").foregroundStyle(e.outcome == "miss" ? theme.del : e.outcome == "hit" ? theme.add : theme.inkDim)
                if showConcept { Text(t.nameOf(e.concept)).foregroundStyle(theme.ink) }
                Field(value: e.level)
                Field(value: e.credit)
                Field(value: (e.confidence ?? "").isEmpty ? "no rating" : e.confidence!)
                Text("\(e.at)\(e.rung == "invent" ? " · invent" : "")\(e.via.map { $0.isEmpty ? "" : " · via \(t.nameOf($0))" } ?? "")")
                    .font(Theme.mono(10.5)).foregroundStyle(theme.inkFaint)
                Spacer()
                if arming { Text("X again cuts it").foregroundStyle(theme.del).font(Theme.mono(11)) }
            }
            .font(Theme.mono(12))
            if on {
                HStack(spacing: 10) {
                    ForEach(["tutor.evidence.outcome", "tutor.evidence.level", "tutor.evidence.credit", "tutor.evidence.confidence", "tutor.evidence.cut"], id: \.self) { id in
                        HStack(spacing: 3) { TutorKey(id: id); Text(app.registry.command(id)?.label ?? "") }
                    }
                }
                .font(Theme.mono(10.5)).foregroundStyle(theme.inkFaint)
            }
            if !e.note.isEmpty { Text(e.note).font(Theme.mono(12.5)).foregroundStyle(theme.inkDim).fixedSize(horizontal: false, vertical: true) }
            if let c = e.contrast, !c.isEmpty { Text("re-test with: \(c)").font(Theme.mono(12)).foregroundStyle(theme.inkFaint) }
        }
    }

    struct Field: View {
        @Environment(\.theme) private var theme
        let value: String
        var body: some View {
            Text(value).font(Theme.mono(11)).foregroundStyle(theme.inkDim).padding(.horizontal, 4).padding(.vertical, 1).overlay(Rectangle().stroke(theme.rule))
        }
    }
}

/// The pinned file — one commit's copy (its ref, else the checkout's HEAD), a line per row so the
/// pane's cursor is a line; space k and the g keys ask at it.
struct PinnedCode: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        let t = TutorArea.state(app)
        if let p = t.pin {
            let lit = p.lit
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text(p.path).foregroundStyle(theme.inkDim).lineLimit(1)
                    Spacer()
                    Text("\(lit.map { "L\($0.0)–\($0.1) · " } ?? "")\(Self.short(t.code?.ref ?? "…"))").foregroundStyle(theme.inkFaint)
                }
                .font(Theme.mono(11)).padding(.horizontal, 14).padding(.vertical, 7).background(theme.vellumRaise)
                theme.rule.frame(height: 1)
                if let err = t.code?.err {
                    Text(err).font(Theme.mono(12)).foregroundStyle(theme.del).padding(14)
                } else if let text = t.code?.text {
                    let lines = TutorRows.lines(text)
                    let focused = app.isFocused(TutorPane.code)
                    ScrollViewReader { proxy in
                        ScrollView([.vertical, .horizontal]) {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(lines.indices, id: \.self) { i in
                                    let n = i + 1
                                    let isLit = lit.map { n >= $0.0 && n <= $0.1 } ?? false
                                    let on = focused && app.selected == "L:\(n)"
                                    HStack(spacing: 0) {
                                        Text("\(n)").foregroundStyle(theme.inkFaint).frame(width: 48, alignment: .trailing).padding(.trailing, 12)
                                        Text(lines[i].isEmpty ? " " : lines[i]).foregroundStyle(isLit || on ? theme.ink : theme.inkDim).fixedSize()
                                    }
                                    .font(Theme.mono(11.5))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(on ? theme.goldWash.opacity(3) : isLit ? theme.goldWash : .clear)
                                    .overlay(alignment: .leading) { if on { theme.goldLeaf.frame(width: 2) } }
                                    .id(TutorScroll.id(TutorPane.code, "L:\(n)"))
                                }
                            }
                            .padding(.vertical, 6)
                        }
                        .modifier(FollowCursor(panes: [TutorPane.code], proxy: proxy))
                        .onAppear { if let l = lit { proxy.scrollTo(TutorScroll.id(TutorPane.code, "L:\(l.0)"), anchor: .center) } }
                        .onChange(of: p) { _, np in if let l = np.lit { proxy.scrollTo(TutorScroll.id(TutorPane.code, "L:\(l.0)"), anchor: .center) } }
                    }
                } else {
                    Text("reading \(p.path)…").font(Theme.mono(12)).foregroundStyle(theme.inkFaint).padding(14)
                }
            }
            .background(theme.diffBg)
            .tutorPane(TutorPane.code)
            .overlay(alignment: .bottom) { TypesPop() }
        }
    }

    static func short(_ ref: String) -> String {
        ref.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil ? String(ref.prefix(10)) : ref
    }
}

/// The space k popover: the type in markdown, or a line saying what tsgo is doing (or why not).
struct TypesPop: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        let t = TutorArea.state(app)
        if let pop = t.pop {
            Group {
                switch pop {
                case .wait(let s): Text(s).foregroundStyle(theme.inkDim)
                case .note(let s): Text(s).foregroundStyle(theme.inkDim)
                case .hover(let md): TutorProse(text: md, size: 12.5)
                }
            }
            .font(Theme.mono(12))
            .padding(10)
            .frame(maxWidth: 560, alignment: .leading)
            .background(theme.vellumRaise)
            .overlay(Rectangle().stroke(theme.rule))
            .padding(12)
        }
    }
}

// ── the concept drawer ───────────────────────────────────────────────────

struct TutorDrawer: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        @Bindable var t = TutorArea.state(app)
        let id = t.drawer ?? ""
        let P = TutorPane.drawer
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let c = t.concept(id) {
                        TutorRow(pane: P, key: "dh:\(id)") { _ in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    TutorLabel(c.kind == "convention" ? "convention · told, then tested" : "principle · derivable")
                                    Spacer()
                                    HStack(spacing: 3) { TutorKey(id: "tutor.back"); Text("✕") }.font(Theme.mono(11)).foregroundStyle(theme.inkFaint)
                                }
                                Text(c.name).font(Theme.display(22)).foregroundStyle(theme.ink)
                                if let mine = c.statement_learner, !mine.isEmpty {
                                    TutorLabel("in your words\(c.restated.map { " · \($0)" } ?? "")")
                                    Text("“\(mine)”").font(.system(size: 15, design: .serif)).foregroundStyle(theme.goldLeaf)
                                    TutorLabel("the tutor's version")
                                }
                                Text(c.statement).font(.system(size: 14.5, design: .serif)).foregroundStyle(theme.inkDim).fixedSize(horizontal: false, vertical: true)
                                DepthBox(c: c)
                                HStack(spacing: 10) {
                                    HStack(spacing: 3) { Text("re-test me cold"); TutorKey(id: "tutor.retest") }
                                        .foregroundStyle(t.streaming ? theme.inkFaint : theme.goldLeaf)
                                    Text(":tutor.teach — teach me this").foregroundStyle(theme.inkFaint)
                                }
                                .font(Theme.mono(12))
                            }
                        }
                        .padding(.bottom, 8)

                        let groups = TutorRows.links(t, c)
                        let offsets = groups.indices.map { g in groups[..<g].reduce(0) { $0 + $1.ids.count } }
                        ForEach(Array(groups.enumerated()), id: \.offset) { g, group in
                            TutorLabel(group.label).padding(.horizontal, 8).padding(.top, 8)
                            ForEach(Array(group.ids.enumerated()), id: \.offset) { j, lid in
                                TutorRow(pane: P, key: "dl:\(offsets[g] + j):\(lid)") { on in ConceptChip(id: lid, on: on) }
                            }
                        }
                        if !c.topics.isEmpty {
                            Text("in: \(c.topics.map { t.learn?.topics[$0]?.title ?? $0 }.joined(separator: " · "))")
                                .font(Theme.mono(10.5)).foregroundStyle(theme.inkFaint).padding(8)
                        }
                        if !c.code.isEmpty {
                            TutorLabel("code").padding(.horizontal, 8).padding(.top, 8)
                            ForEach(Array(c.code.enumerated()), id: \.offset) { n, r in
                                TutorRow(pane: P, key: "dc:\(n)") { on in
                                    HStack(spacing: 8) {
                                        Text("\(r.path)\(r.lines.map { $0.isEmpty ? "" : " L\($0[0])–\($0.count > 1 ? $0[1] : $0[0])" } ?? "")").lineLimit(1)
                                        if on { Text(t.active != nil ? "↵ show in the code pane" : "open a session to see code").foregroundStyle(theme.ember) }
                                    }
                                    .font(Theme.mono(11)).foregroundStyle(theme.inkDim)
                                }
                            }
                        }

                        TutorLabel("your questions").padding(.horizontal, 8).padding(.top, 12)
                        ForEach(TutorRows.drawerQuestions(t, id), id: \.id) { q in
                            TutorRow(pane: P, key: "q:\(q.id)") { on in
                                HStack(alignment: .firstTextBaseline) {
                                    Text(q.text).strikethrough(q.status != "open").foregroundStyle(q.status == "open" ? theme.ink : theme.inkFaint)
                                    Spacer()
                                    if on { HStack(spacing: 3) { TutorKey(id: "tutor.question.toggle"); Text(q.status == "open" ? "answered" : "reopen") }.foregroundStyle(theme.inkFaint) }
                                }
                                .font(Theme.mono(12.5))
                            }
                        }
                        TutorRow(pane: P, key: "ask") { on in
                            VStack(alignment: .leading, spacing: 3) {
                                ModalTextField(TutorCommands.insertField.question, prompt: t.active != nil ? "ask the tutor about this…" : "ask — starts a session on it", text: $t.question)
                                    .font(Theme.mono(12.5)).padding(.horizontal, 8).padding(.vertical, 4)
                                    .background(theme.vellumNight)
                                    .overlay(Rectangle().stroke(app.insertField == TutorCommands.insertField.question ? theme.goldDeep : theme.rule))
                                if on || app.insertField == TutorCommands.insertField.question {
                                    HStack(spacing: 3) { TutorKey(id: "tutor.write"); Text("types · ↵ asks") }.font(Theme.mono(10.5)).foregroundStyle(theme.inkFaint)
                                }
                            }
                        }

                        TutorLabel("evidence · newest first").padding(.horizontal, 8).padding(.top, 12)
                        Text("depth comes only from this — toggle hit/miss, change level or credit, or cut a row")
                            .font(Theme.mono(11.5)).foregroundStyle(theme.inkFaint).padding(.horizontal, 8).padding(.bottom, 4)
                        let ev = TutorRows.drawerEvidence(t, id)
                        if ev.isEmpty { Text("none yet").font(Theme.mono(12)).foregroundStyle(theme.inkFaint).padding(.horizontal, 8) }
                        ForEach(ev, id: \.id) { e in
                            TutorRow(pane: P, key: "e:\(e.id)") { on in EvidenceRow(e: e, on: on) }
                        }
                    } else {
                        TutorRow(pane: P, key: "dh:\(id)") { _ in Text("no concept \(id)").foregroundStyle(theme.inkFaint) }
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 16)
            }
            .modifier(FollowCursor(panes: [P], proxy: proxy))
        }
        .background(theme.vellumRaise)
        .overlay(alignment: .leading) { theme.goldDeep.frame(width: 1) }
        .tutorPane(P)
        .shadow(color: .black.opacity(0.45), radius: 16, x: -12)
    }
}

struct DepthBox: View {
    @Environment(\.theme) private var theme
    let c: Concept

    var body: some View {
        let m = c.mastery
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Pips(m: m, size: 9)
                Text((m.held ?? 0) != 0
                     ? "held at \(m.held_level ?? "")\(m.depth > (m.held ?? 0) ? " · shown once at \(m.level)" : "")"
                     : !m.level.isEmpty ? "shown once at \(m.level) — a second day makes it held" : "not yet shown unaided")
                    .font(Theme.mono(12.5)).foregroundStyle(theme.ink)
            }
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 1) {
                ForEach(Lesson.levels, id: \.self) { l in
                    GridRow { Text(l).frame(width: 72, alignment: .leading); Text(Lesson.levelHint[l] ?? "") }
                }
            }
            .font(Theme.mono(10.5)).foregroundStyle(theme.inkFaint)
            if m.due {
                Text("due\(m.miss_confidence == "high" ? " (a confident miss — re-test first)" : ""): \(m.reason)").font(Theme.mono(12)).foregroundStyle(theme.ember)
            }
            if let ct = m.contrast, !ct.isEmpty { Text("re-test with the contrast: \(ct)").font(Theme.mono(12)).foregroundStyle(theme.inkDim) }
        }
        .padding(12)
        .background(theme.vellumNight)
        .overlay(Rectangle().stroke(theme.rule))
    }
}
