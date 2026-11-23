import CanopyCore
import SwiftUI

/// Forests.tsx, the home: one list of everything that can need Phil — forests, PRs of mine no forest carries, PRs
/// awaiting my review, chats owed a reply — each once, grouped by whose move it is (round 30), then the work
/// elsewhere and a quiet archive count. Each forest is one calm row that ↵ opens on its own page (the palette's "open or fold" unfolds its branch
/// spine inline, in merge order); each branch says where it stands in one glyph and word and does
/// one thing on ↵. `, r` narrows it all to what's ready.
struct ForestsPage: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduced

    var body: some View {
        let m = app.forestModel
        let p = m.projects()
        let fs = m.forests()
        let rows = m.homeRows()
        let working = WorkInProgressView.placed(app)
        let focused = app.isFocused("main")
        let cursor = focused ? app.selected : nil
        let selection = focused ? Set(app.selection) : []
        let shown = p.focus + p.workbench + (m.showArchive ? p.archive : [])
        let nameWidth = CGFloat(min(32, max(14, (shown.map { $0.name.count + 2 }.max() ?? 14)))) * 8.4
        Group {
            if !app.store.ready {
                Text("reading the forests…").foregroundStyle(theme.inkFaint).padding(.leading, 44)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            WindowLine(fs: fs, now: m.now)
                            if m.readyOnly {
                                let n = fs.values.filter { $0.p.state != .archive }.reduce(0) { $0 + $1.ready.count }
                                HStack(spacing: 6) {
                                    Text("ready").foregroundStyle(theme.goldLeaf)
                                    Text("· \(n == 0 ? "nothing" : String(n)) ·").foregroundStyle(theme.inkDim)
                                    Button("show all") { app.runner.dispatch("ready.toggle", via: .click) }
                                        .buttonStyle(.plain).foregroundStyle(theme.inkFaint)
                                        .labelTarget(pane: "controls", key: "ready.toggle", title: "show all", run: RouteTo("ready.toggle"))
                                    KeyHint(id: "ready.toggle")
                                }
                                .padding(.leading, 44).padding(.bottom, 20)
                                section(.focus, p.focus, fs, working, nameWidth: nameWidth, cursor: cursor, selection: selection)
                                section(.workbench, p.workbench, fs, working, nameWidth: nameWidth, cursor: cursor, selection: selection)
                            } else {
                                let home = m.homeSections()
                                if !home.cards.isEmpty || !m.reviewRequests.isEmpty {
                                    PRCards(cards: home.cards, asked: m.reviewRequests, cursor: cursor, selection: selection)
                                }
                                ForEach(home.sections, id: \.verb) { sec in
                                    if sec.verb == .push {
                                        PushChips(items: sec.items, fs: fs, cursor: cursor, selection: selection)
                                    } else {
                                        HomeGroup(verb: sec.verb, items: sec.items, fs: fs, working: working, nameWidth: nameWidth, cursor: cursor, selection: selection)
                                    }
                                }
                                // what needs nothing from you sits below what does (round 29, P5)
                                WorkInProgressView()
                                if m.showArchive {
                                    section(.archive, p.archive, fs, working, nameWidth: nameWidth, cursor: cursor, selection: selection)
                                } else if !p.archive.isEmpty {
                                    HStack(spacing: 6) {
                                        Button("archive · \(p.archive.count)") { app.runner.dispatch("archive.toggle", via: .click) }
                                            .buttonStyle(.plain).foregroundStyle(theme.inkFaint)
                                            .labelTarget(pane: "controls", key: "archive.toggle", title: "archive", run: RouteTo("archive.toggle"))
                                        KeyHint(id: "archive.toggle")
                                    }
                                    .padding(.leading, 44)
                                    .settles(p.archive.count, reduced: reduced)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                        .glides(rows, reduced: reduced)
                    }
                    .labelPane("main")
                    .labelPane("work")
                    .onChange(of: cursor) { _, k in if let k { proxy.scrollTo(k) } }
                    .onChange(of: app.selected) { _, k in if let k, app.isFocused("work") { proxy.scrollTo(k) } }
                }
            }
        }
        .padding(.horizontal, 16).padding(.bottom, 8)
        .onChange(of: m.closedIDs(), initial: true) { _, _ in m.syncClosings() }
        .task { await tick(m) }
        .task { await pollReviews(m) }
        // a diverged branch's situation turns on its tip's prep route and force scope: the home reads them too, so
        // its dot and `p` on the branch's page say the same thing
        .task(id: divergedKey(fs)) {
            let ship = ShipState.of(app)
            for v in fs.values.flatMap(\.branches) where v.b.diverged && v.st.ship != .landed {
                ship.readFacts(app, v.b, key: ShipState.factsKey(v.b, ship.motionOf(v.b.id), v.pr))
                ship.readForceScope(app, v.b.id)
            }
        }
        // the cursor landing on a branch warms its review page's diff (Forests.tsx warmSelected)
        .onChange(of: cursor, initial: true) { _, k in
            if let b = RowKey.id(k, "b").flatMap({ app.store.view(Branch.self, $0) }) { ReviewPageState.of(app).warm(b) }
        }
        // the cursor resting on a forest asks whether it merges — a second of git, so only the one you stop on
        .task(id: cursor) {
            guard let pid = RowKey.id(cursor, "p") else { return }
            try? await Task.sleep(nanoseconds: 700_000_000)
            if !Task.isCancelled { await m.checkIntegration(pid) }
        }
    }

    @ViewBuilder
    private func section(_ state: ProjectState, _ projects: [Project], _ fs: [String: ForestView], _ working: [String: [TodoItem]], nameWidth: CGFloat, cursor: String?, selection: Set<String>) -> some View {
        let m = app.forestModel
        let views = projects.compactMap { fs[$0.id] }.filter { !m.readyOnly || !$0.ready.isEmpty }
        if !m.readyOnly || !views.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                if state != .focus {
                    TermText("lane|\(state.rawValue)", state).font(Theme.text(11)).foregroundStyle(theme.inkFaint)
                        .padding(.leading, 44).padding(.bottom, 4)
                }
                if views.isEmpty {
                    Text("empty").foregroundStyle(theme.inkFaint).padding(.leading, 44).padding(.vertical, 8)
                }
                ForEach(views, id: \.p.id) { f in
                    // one line per forest: its chats ride that line; a branch gets its own line only for its own work in
                    // progress, and the forest's tracker context is on the forest's page
                    ForestRowView(f: f, nameWidth: nameWidth, cursor: cursor == RowKey.project(f.p.id), selected: selection.contains(RowKey.project(f.p.id)))
                    ForEach(Self.workLines(f, working), id: \.item.id) { l in BranchWorkLine(branch: l.branch, item: l.item) }
                    if m.launching == f.p.id { LaunchLine(f: f) }
                    let ids = m.readyOnly ? f.ready : m.expanded.contains(f.p.id) ? f.branches : []
                    ForEach(ids, id: \.b.id) { v in
                        BranchRowView(v: v, summary: f.p.summary, cursor: cursor == RowKey.branch(v.b.id), selected: selection.contains(RowKey.branch(v.b.id)))
                    }
                }
            }
            .padding(.bottom, 28)
        }
    }

    /// The lines under a forest's row: one per item of work in progress on one of its branches, in merge order.
    static func workLines(_ f: ForestView, _ working: [String: [TodoItem]]) -> [(branch: Branch, item: TodoItem)] {
        f.branches.flatMap { v in (working[v.b.id] ?? []).map { (v.b, $0) } }
    }

    private func divergedKey(_ fs: [String: ForestView]) -> String {
        fs.values.flatMap(\.branches).filter { $0.b.diverged && $0.st.ship != .landed }.map { "\($0.b.id)@\($0.b.tip)" }.sorted().joined(separator: ",")
    }

    private func pollReviews(_ m: ForestModel) async {
        while !Task.isCancelled {
            await m.loadReviewRequests()
            await m.loadMyPRs()
            await m.loadPRSignals()
            try? await Task.sleep(nanoseconds: 60_000_000_000)
        }
    }

    private func tick(_ m: ForestModel) async {
        while !Task.isCancelled {
            m.now = Date()
            try? await Task.sleep(nanoseconds: 30_000_000_000)
        }
    }
}

/// One group of the home (rounds 30–31): its verb as the head, then each item once, every row in the one shape `HomeLine` draws.
private struct HomeGroup: View {
    @Environment(AppModel.self) private var app
    let verb: HomeVerb
    let items: [HomeItem]
    let fs: [String: ForestView]
    let working: [String: [TodoItem]]
    let nameWidth: CGFloat
    let cursor: String?
    let selection: Set<String>

    var body: some View {
        let m = app.forestModel
        VStack(alignment: .leading, spacing: 0) {
            SectionHead(text: "\(verb.title) · \(items.count)", gold: verb.isYours).padding(.leading, 44).padding(.bottom, 4)
            ForEach(items, id: \.key) { item in
                switch item {
                case .forest(let p):
                    if let f = fs[p.id] {
                        ForestRowView(f: f, nameWidth: nameWidth, cursor: cursor == item.key, selected: selection.contains(item.key))
                        ForEach(ForestsPage.workLines(f, working), id: \.item.id) { l in BranchWorkLine(branch: l.branch, item: l.item) }
                        if m.launching == f.p.id { LaunchLine(f: f) }
                        ForEach(m.expanded.contains(f.p.id) ? f.branches : [], id: \.b.id) { v in
                            BranchRowView(v: v, summary: f.p.summary, cursor: cursor == RowKey.branch(v.b.id), selected: selection.contains(RowKey.branch(v.b.id)))
                        }
                    }
                case .myPR(let p):
                    HomeLine(key: item.key, nameWidth: nameWidth, cursor: cursor, selection: selection, yours: verb.isYours,
                             name: p.local ? p.head : "#\(p.number)", line: p.title, pr: PRCell(numbers: [p.number], state: PRState.of(p), signals: m.prSignals[p.number]),
                             step: m.openPRRows().first { $0.mine?.number == p.number }?.says ?? "")
                case .review(let r):
                    HomeLine(key: item.key, nameWidth: nameWidth, cursor: cursor, selection: selection, yours: true,
                             name: "#\(r.number)", line: r.title, pr: PRCell(note: r.author), step: "review",
                             stepHelp: r.imported ? "its head is local as review/pr-\(r.number): ↵ opens it at once" : "↵ fetches its head first, a second or two")
                case .reply(let chat, let forests):
                    HomeLine(key: item.key, nameWidth: nameWidth, cursor: cursor, selection: selection, yours: true,
                             name: "reply to Claude", line: forests.map(\.name).joined(separator: ", "), pr: PRCell(),
                             step: "idle \(WorkContext.ago(m.now.timeIntervalSince1970 - chat.activeAt).replacingOccurrences(of: " ago", with: ""))",
                             stepHelp: "chat \(chat.id.prefix(8)) · ↵ brings its pane forward")
                }
            }
        }
        .padding(.bottom, 28)
    }
}

/// The home's top (rounds 32–36): two columns of cards. Left, each of my open PRs that isn't a draft — what it asks
/// (merge, in review, after its parent), its number and title, GitHub's state and signals, where it lives — keyed
/// ⌥1…; right, each PR I'm asked to review, keyed ⌥a…. `j`/`k` move down a column, `h`/`l` across; ↵ reviews one.
private struct PRCards: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    let cards: [OpenPRRow]
    let asked: [ReviewRequest]
    let cursor: String?
    let selection: Set<String>

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            column("your PRs · \(cards.count)") {
                ForEach(Array(cards.enumerated()), id: \.element.key) { i, r in card(r, n: i + 1) }
            }
            column("review · \(asked.count)") {
                ForEach(Array(asked.enumerated()), id: \.element.number) { i, r in askedCard(r, n: i + 1) }
            }
        }
        .padding(.leading, 28).padding(.trailing, 16).padding(.top, 6).padding(.bottom, 30)
    }

    private func column<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHead(text: title, gold: true).padding(.leading, 16)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func askedCard(_ r: ReviewRequest, n: Int) -> some View {
        let key = RowKey.reviewRequest(r.number)
        let here = cursor == key
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if n <= Verbs.askedLetters.count {
                    Text(verbatim: "⌥\(Verbs.askedLetters[n - 1])").font(Theme.text(11, weight: .semibold))
                        .foregroundStyle(here ? theme.goldLeaf : theme.inkFaint)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(here ? theme.goldLeaf.opacity(0.6) : theme.vellumEdge, lineWidth: 1))
                }
                Text(verbatim: "REVIEW").font(Theme.display(20)).tracking(1.2).foregroundStyle(theme.goldLeaf)
                Spacer(minLength: 8)
                Text(verbatim: "#\(r.number)").font(Theme.text(13, weight: .medium)).monospacedDigit().foregroundStyle(here ? theme.goldLeaf : theme.inkDim)
            }
            Text(verbatim: r.title).font(Theme.text(14)).foregroundStyle(theme.ink).lineLimit(2, reservesSpace: true)
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Text(verbatim: r.author).font(Theme.text(11)).foregroundStyle(theme.inkDim)
                Text(verbatim: r.imported ? "loaded" : "on GitHub").font(Theme.text(11)).foregroundStyle(theme.inkFaint)
                    .help(r.imported ? "its head is local as review/pr-\(r.number): ↵ opens it at once" : "↵ fetches its head first, a second or two")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(here ? theme.goldLeaf.opacity(0.12) : theme.vellumRaise))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(here ? theme.goldLeaf.opacity(0.7) : theme.goldDeep, lineWidth: here ? 1.5 : 1))
        .contentShape(Rectangle())
        .onTapGesture { app.runner.dispatch("cursor.set", via: .click, target: key) }
        .labelTarget(pane: "main", key: key)
        .id(key)
    }

    private func card(_ r: OpenPRRow, n: Int) -> some View {
        let here = cursor == r.key
        let ask = r.ask
        let state = r.state
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if n <= 9 { OptionDigitBadge(n: n, lit: here) }
                Text(verbatim: ask.word.uppercased()).font(Theme.display(20)).tracking(1.2)
                    .foregroundStyle(ask.yours ? theme.goldLeaf : theme.inkDim).lineLimit(1)
                Spacer(minLength: 8)
                Text(verbatim: "#\(r.number)").font(Theme.text(13, weight: .medium)).monospacedDigit().foregroundStyle(here ? theme.goldLeaf : theme.inkDim)
            }
            Text(verbatim: r.title).font(Theme.text(14)).foregroundStyle(theme.ink).lineLimit(2, reservesSpace: true)
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                if let state { Text(verbatim: state.word).font(Theme.text(11)).foregroundStyle(PRCell.color(state.tone, theme)) }
                PRSignalStrip(signals: r.signals)
            }
            Text(verbatim: r.place).font(Theme.text(11)).foregroundStyle(theme.inkFaint).lineLimit(1)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(here ? theme.goldLeaf.opacity(0.12) : theme.vellumRaise))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(here ? theme.goldLeaf.opacity(0.7) : ask.yours ? theme.goldDeep : theme.vellumEdge, lineWidth: here ? 1.5 : 1))
        .contentShape(Rectangle())
        .onTapGesture { app.runner.dispatch("cursor.set", via: .click, target: r.key) }
        .labelTarget(pane: "main", key: r.key)
        .help(r.says)
        .id(r.key)
    }
}

/// The push group (rounds 31–32): every forest whose next step is a push, as one wrapping run of chips — the name and
/// how many of its branches wait to go. `h`/`l` walk them; ↵ opens a forest, where `p` sends them.
private struct PushChips: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    let items: [HomeItem]
    let fs: [String: ForestView]
    let cursor: String?
    let selection: Set<String>

    static func waiting(_ f: ForestView) -> Int {
        f.branches.filter { ["branch.push.arm", "branch.push.queue", "branch.push.early.arm"].contains($0.st.next ?? "") }.count
    }

    var body: some View {
        let forests = items.compactMap { item -> (key: String, f: ForestView)? in
            if case .forest(let p) = item, let f = fs[p.id] { return (item.key, f) }
            return nil
        }
        let branches = forests.reduce(0) { $0 + Self.waiting($1.f) }
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                SectionHead(text: "push · \(forests.count) \(forests.count == 1 ? "forest" : "forests") · \(branches) \(branches == 1 ? "branch" : "branches")", gold: true)
                let green = app.forestModel.greenPushes()
                if !green.isEmpty {
                    let armed = app.runner.armed?.hasPrefix("push green ") == true
                    Text(verbatim: armed ? "\(green.count) ready to send — again to push" : "\(green.count) green")
                        .font(Theme.text(11)).foregroundStyle(armed ? theme.goldLeaf : theme.inkFaint)
                    KeyHint(id: "forests.push.green")
                }
            }
            .padding(.leading, 44)
            ChipFlow(spacing: 8) {
                ForEach(forests, id: \.key) { c in
                    let here = cursor == c.key
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(verbatim: c.f.p.name).font(Theme.text(13, weight: .medium)).foregroundStyle(here ? theme.goldLeaf : theme.ink)
                        Text(verbatim: "\(Self.waiting(c.f))").font(Theme.text(11)).monospacedDigit().foregroundStyle(theme.inkFaint)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 6).fill(here ? theme.goldLeaf.opacity(0.14) : theme.vellumRaise))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(here ? theme.goldLeaf.opacity(0.6) : theme.vellumEdge, lineWidth: 1))
                    .contentShape(Rectangle())
                    .onTapGesture { app.runner.dispatch("cursor.set", via: .click, target: c.key) }
                    .labelTarget(pane: "main", key: c.key)
                    .help(c.f.says)
                    .id(c.key)
                }
            }
            .padding(.leading, 40).padding(.trailing, 16)
        }
        .padding(.bottom, 28)
    }
}

/// Lays its children left to right, wrapping onto a new line when the next one won't fit.
struct ChipFlow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: rows.last.map { $0.y + $0.height } ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(width: bounds.width, subviews) {
            for (i, x) in zip(row.items, row.xs) {
                subviews[i].place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + row.y), proposal: .unspecified)
            }
        }
    }

    private struct Row { var items: [Int] = []; var xs: [CGFloat] = []; var y: CGFloat = 0; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, _ subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for (i, v) in subviews.enumerated() {
            let size = v.sizeThatFits(.unspecified)
            if !rows[rows.count - 1].items.isEmpty && rows[rows.count - 1].width + spacing + size.width > width {
                let last = rows[rows.count - 1]
                rows.append(Row(y: last.y + last.height + spacing))
            }
            var r = rows[rows.count - 1]
            let x = r.items.isEmpty ? 0 : r.width + spacing
            r.items.append(i); r.xs.append(x); r.width = x + size.width; r.height = max(r.height, size.height)
            rows[rows.count - 1] = r
        }
        return rows
    }
}

/// The home's one row shape: name, its line, the PR column, the step. The right two columns are fixed-width on every
/// row, so they line up down the page whatever the row is.
enum HomeColumns {
    static let pr: CGFloat = 360
    static let step: CGFloat = 170
}

private struct HomeLine: View {
    @Environment(\.theme) private var theme
    let key: String
    let nameWidth: CGFloat
    let cursor: String?
    let selection: Set<String>
    let yours: Bool
    let name: String
    let line: String
    let pr: PRCell
    let step: String
    var stepHelp: String?

    var body: some View {
        let here = cursor == key
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("").frame(width: 12)
            Text(verbatim: name).font(Theme.display(17)).foregroundStyle(here ? theme.goldLeaf : theme.ink)
                .lineLimit(1).truncationMode(.tail).frame(width: nameWidth, alignment: .leading)
            Text(verbatim: line).foregroundStyle(theme.inkDim).lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading)
            pr
            StepText(step: step, yours: yours, here: here).help(stepHelp ?? step)
        }
        .frame(height: 30)
        .padding(.horizontal, 16)
        .rowChrome(key, cursor: here, selected: selection.contains(key))
    }
}

/// A row's PR column: its open PRs' numbers, the lead PR's state in GitHub's words, and its signals — or a quiet note.
struct PRCell: View {
    @Environment(\.theme) private var theme
    var numbers: [Int] = []
    var state: PRState?
    var signals: PRSignals?
    var note = ""
    /// false where the cell stands alone (the lead) rather than in the home's aligned column
    var column = true

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            if !numbers.isEmpty {
                Text(verbatim: numbers.map { "#\($0)" }.joined(separator: " ")).font(Theme.text(11)).monospacedDigit().foregroundStyle(theme.inkFaint)
                    .fixedSize()
                if let state { Text(verbatim: state.word).font(Theme.text(11)).foregroundStyle(color(state.tone)).fixedSize() }
                PRSignalStrip(signals: signals)
            } else if !note.isEmpty {
                Text(verbatim: note).font(Theme.text(11)).foregroundStyle(theme.inkFaint).lineLimit(1)
            }
        }
        .frame(width: column ? HomeColumns.pr : nil, alignment: .leading)
        .clipped()
    }

    private func color(_ t: PRState.Tone) -> Color { Self.color(t, theme) }

    static func color(_ t: PRState.Tone, _ theme: Theme) -> Color {
        switch t {
        case .ready: theme.add
        case .blocked: theme.del
        case .waiting: theme.goldLeaf
        case .quiet: theme.inkFaint
        }
    }
}

extension OpenPRRow {
    /// What the PR asks of Phil, as its card's verb, and whether it's his to do now.
    var ask: (word: String, yours: Bool) {
        if let w = branch?.st.waiting.first, w.kind == .parent, let n = w.label.split(separator: " ").first(where: { $0.hasPrefix("#") }) {
            return ("after \(n)", false)
        }
        if branch?.st.actor == .parent, let parent = branch?.b.parent { return ("after \(leaf(parent))", false) }
        switch says {
        case "merge it": return ("merge", true)
        case "changes requested": return ("fix", true)
        case "waiting on review": return ("in review", false)
        case "waiting on required checks": return ("checks", false)
        default: return (says, yours)
        }
    }

    /// GitHub's state for it, in its PR list's words.
    var state: PRState? { branch?.pr.map(PRState.of) ?? mine.map(PRState.of) }
}

/// A PR's `⌥n` badge: the key that reviews it from any page.
struct OptionDigitBadge: View {
    @Environment(\.theme) private var theme
    let n: Int
    var lit = false

    var body: some View {
        Text(verbatim: "⌥\(n)").font(Theme.text(11, weight: .semibold)).monospacedDigit()
            .foregroundStyle(lit ? theme.goldLeaf : theme.inkFaint)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(lit ? theme.goldLeaf.opacity(0.6) : theme.vellumEdge, lineWidth: 1))
    }
}

/// An open PR's state as GitHub's PR list words it: what the row's PR column says beside its number.
struct PRState: Equatable {
    enum Tone { case ready, blocked, waiting, quiet }
    var word: String
    var tone: Tone

    static func of(draft: Bool, review: String?, approvals: Int, changesRequested: Bool, mergeState: String?, mergeable: String? = nil) -> PRState {
        let ms = (mergeState ?? "").uppercased()
        if draft { return PRState(word: "draft", tone: .quiet) }
        if changesRequested || review == "CHANGES_REQUESTED" { return PRState(word: "changes requested", tone: .blocked) }
        if mergeable == "CONFLICTING" || ms == "DIRTY" { return PRState(word: "conflicts", tone: .blocked) }
        if review == "APPROVED" || approvals > 0 {
            return ms == "CLEAN" || ms == "HAS_HOOKS" ? PRState(word: "ready to merge", tone: .ready) : PRState(word: "approved", tone: .ready)
        }
        return PRState(word: "waiting for review", tone: .waiting)
    }

    static func of(_ pr: Pr) -> PRState {
        of(draft: pr.draft, review: pr.review, approvals: pr.approvals ?? 0, changesRequested: false, mergeState: pr.mergeState, mergeable: pr.mergeable)
    }

    static func of(_ p: MyPR) -> PRState {
        of(draft: p.draft, review: nil, approvals: p.approvals ?? 0, changesRequested: p.changesRequested == true, mergeState: p.mergeState)
    }
}

/// A row's one step. Most rows say "push", so the step stays quiet until the cursor rests on its row.
private struct StepText: View {
    @Environment(\.theme) private var theme
    let step: String
    let yours: Bool
    let here: Bool

    var body: some View {
        Text(verbatim: step).font(Theme.text(11)).foregroundStyle(here ? theme.ink : yours ? theme.inkDim : theme.inkFaint)
            .lineLimit(1).truncationMode(.tail).frame(width: HomeColumns.step, alignment: .trailing)
    }
}

/// One open PR's GitHub signals as GitHub's checks summary draws them — passed, failed, running and queued
/// checks, then unresolved threads, comments, approvals or changes requested, conflicts; a zero draws nothing.
struct PRSignalStrip: View {
    @Environment(\.theme) private var theme
    let signals: PRSignals?

    struct Mark: Equatable {
        var symbol: String
        var count: Int?
        var tone: Tone
        var help: String
    }
    enum Tone { case pass, fail, running, quiet, note }

    static func marks(_ s: PRSignals) -> [Mark] {
        var out: [Mark] = []
        func add(_ n: Int, _ symbol: String, _ tone: Tone, _ help: String) {
            if n > 0 { out.append(Mark(symbol: symbol, count: n, tone: tone, help: "\(n) \(help)")) }
        }
        if s.conflicts { out.append(Mark(symbol: "exclamationmark.triangle.fill", count: nil, tone: .fail, help: "conflicts with its base")) }
        add(s.checks.pass, "checkmark.circle.fill", .pass, "checks passed")
        add(s.checks.fail, "xmark.circle.fill", .fail, "checks failed")
        add(s.checks.running, "clock", .running, "checks running")
        add(s.checks.queued, "circle.dashed", .quiet, "checks queued")
        add(s.threads, "text.bubble.fill", .note, s.threads == 1 ? "unresolved thread" : "unresolved threads")
        add(s.comments, "bubble.left", .quiet, s.comments == 1 ? "comment" : "comments")
        if s.changesRequested {
            out.append(Mark(symbol: "hand.raised.fill", count: nil, tone: .fail, help: "changes requested"))
        } else {
            add(s.approvals, "person.fill.checkmark", .pass, s.approvals == 1 ? "approval" : "approvals")
        }
        return out
    }

    private func color(_ t: Tone) -> Color {
        switch t {
        case .pass: theme.add
        case .fail: theme.del
        case .running: theme.goldLeaf
        case .quiet: theme.inkFaint
        case .note: theme.ink
        }
    }

    var body: some View {
        HStack(spacing: 9) {
            ForEach(signals.map(Self.marks) ?? [], id: \.symbol) { m in
                HStack(spacing: 3) {
                    Image(systemName: m.symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(color(m.tone))
                    if let n = m.count { Text(verbatim: "\(n)").font(Theme.text(11)).foregroundStyle(theme.inkDim) }
                }
                .help(m.help)
            }
        }
        .lineLimit(1)
    }
}

/// Chats whose turn ended, each once with the forests it's on (round 29): ↵ brings its pane forward.
private struct ReplyQueue: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    let nameWidth: CGFloat
    let cursor: String?
    let selection: Set<String>

    var body: some View {
        let replies = app.forestModel.replies()
        if !replies.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(replies, id: \.chat.id) { r in
                    let key = RowKey.reply(r.chat.id)
                    let here = cursor == key
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text("").frame(width: 12)
                        Text("reply to Claude").font(Theme.display(17)).foregroundStyle(here ? theme.goldLeaf : theme.ink)
                            .lineLimit(1).frame(width: nameWidth, alignment: .leading)
                        Text(r.forests.map(\.name).joined(separator: ", ")).foregroundStyle(theme.inkDim).lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("idle \(WorkContext.ago(app.forestModel.now.timeIntervalSince1970 - r.chat.activeAt).replacingOccurrences(of: " ago", with: ""))")
                            .font(Theme.text(11)).foregroundStyle(theme.inkFaint).fixedSize()
                            .help("chat \(r.chat.id.prefix(8)) · ↵ brings its pane forward")
                    }
                    .frame(height: 30)
                    .padding(.horizontal, 16)
                    .rowChrome(key, cursor: here, selected: selection.contains(key))
                }
            }
            .padding(.bottom, 28)
        }
    }
}

/// Open PRs GitHub says await my review — reachable here, not only from the PR page's ⌘⇧U. ↵ opens
/// one in canopy, importing its head as review/pr-<N> first if it isn't local yet.
private struct ReviewQueue: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    let nameWidth: CGFloat
    let cursor: String?
    let selection: Set<String>

    var body: some View {
        let queue = app.forestModel.reviewRequests
        if !queue.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text("review").font(Theme.text(11)).foregroundStyle(theme.inkFaint)
                    .explains("lane|review", RowName(word: "review", meaning: "open PRs awaiting your review on GitHub"))
                    .padding(.leading, 44).padding(.bottom, 4)
                ForEach(queue, id: \.number) { r in
                    let key = RowKey.reviewRequest(r.number)
                    let here = cursor == key
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text("").frame(width: 12)
                        Text(verbatim: "#\(r.number)").font(Theme.display(17)).foregroundStyle(here ? theme.goldLeaf : theme.ink)
                            .lineLimit(1).frame(width: nameWidth, alignment: .leading)
                        Text(r.title).foregroundStyle(theme.inkDim).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                        Text(r.author).font(Theme.text(11)).foregroundStyle(theme.inkFaint).fixedSize()
                        Text(r.imported ? "loaded" : "on GitHub").font(Theme.text(11))
                            .foregroundStyle(r.imported ? theme.inkDim : theme.inkFaint).fixedSize()
                            .explains("review|loaded|\(r.number)", RowName(word: r.imported ? "loaded" : "on GitHub",
                                meaning: r.imported ? "its head is local as review/pr-\(r.number): it opens at once"
                                    : "↵ fetches its head first, a second or two"))
                    }
                    .frame(height: 30)
                    .padding(.horizontal, 16)
                    .rowChrome(key, cursor: here, selected: selection.contains(key))
                }
            }
            .padding(.bottom, 28)
        }
    }
}

/// The holds that came due overnight.
private struct WindowLine: View {
    @Environment(\.theme) private var theme
    let fs: [String: ForestView]
    let now: Date

    var body: some View {
        let due = fs.values.flatMap(\.branches).filter { v in v.pr == nil && (v.b.holdUntil.flatMap(parseISO).map { $0 <= now } ?? false) }.count
        if due > 0 {
            Text("☀ \(due) held overnight \(due == 1 ? "is" : "are") due").foregroundColor(theme.goldLeaf)
                .font(Theme.display(15))
                .explains("home|due", RowName(word: "☀ held", meaning: "branches held for the morning push window, now due to push"))
                .padding(.leading, 44).padding(.bottom, 24)
        }
    }
}

private struct ForestRowView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    let f: ForestView
    let nameWidth: CGFloat
    let cursor: Bool
    let selected: Bool

    var body: some View {
        @Bindable var m = app.forestModel
        let p = f.p
        let closing = m.closing.contains(p.id)
        let verdict = m.verdict(p.id)
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            // the focus lane reorders by key (C-k / C-j); the grip only says it can
            Text("⋮").foregroundStyle(theme.inkFaint).opacity(p.state == .focus && cursor ? 1 : 0).frame(width: 12)
            HStack(spacing: 6) {
                let nameField = ProjectCommands.renameField(p.id)
                if app.insertField == nameField {
                    ModalTextField(nameField, prompt: "lowercase-with-dashes", text: LineEdit.of(app).binding(nameField, saved: p.name))
                        .font(Theme.display(17)).foregroundStyle(theme.ink).padding(2).background(theme.vellumRaise)
                } else {
                    Text(LineEdit.of(app).text(nameField, saved: p.name)).font(Theme.display(17))
                        .foregroundStyle(cursor ? theme.goldLeaf : f.closed ? theme.inkFaint : theme.ink)
                        .lineLimit(1).truncationMode(.tail)
                    if LineEdit.of(app).unsaved(nameField, saved: p.name) { UnsavedMark() }
                }
                if verdict?.state == .conflicts {
                    Text("✕").font(Theme.text(11)).foregroundStyle(theme.del)
                        .explains("forest|✕|\(p.id)", RowName(word: "✕", meaning: "its branches don't merge onto main together"))
                }
            }
            .frame(width: nameWidth, alignment: .leading)
            if closing || f.closed {
                Text("✦ canopy closed").font(Theme.display(13)).foregroundStyle(closing ? theme.goldLeaf.opacity(0.8) : theme.inkFaint)
                    .explains("forest|closed|\(p.id)", RowName(word: "✦ closed", meaning: "every branch has landed; it can go to the archive"))
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if ProjectCommands.editing(app)?.project.id == p.id {
                HStack(spacing: 8) {
                    let lineField = ProjectCommands.describeField(p.id)
                    if app.insertField == lineField {
                        ModalTextField(lineField, prompt: "one line: what this forest is for",
                                       text: LineEdit.of(app).binding(lineField, saved: ProjectCommands.ownLine(p)))
                            .foregroundStyle(theme.ink).padding(2).background(theme.vellumRaise)
                    }
                    Text("\(app.registry.keyOf("project.words.save")) saves · esc keeps it unsaved").font(Theme.text(11)).foregroundStyle(theme.inkFaint).fixedSize()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if LineEdit.of(app).unsaved(ProjectCommands.describeField(p.id), saved: ProjectCommands.ownLine(p)) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(LineEdit.of(app).text(ProjectCommands.describeField(p.id), saved: "")).foregroundStyle(theme.inkDim).lineLimit(1)
                    UnsavedMark()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                // Phil's own words read plainly; Claude's draft and a borrowed branch line read fainter
                Text(p.summary).foregroundStyle(p.summaryBy == "phil" ? theme.inkDim : theme.inkFaint).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .explains("forest|line|\(p.id)", RowName(word: "the line", meaning: p.summaryBy == "phil" ? "your words for this forest"
                        : "\(p.summaryBy == "claude" ? "Claude's draft" : "its first branch's") · \(app.registry.keyOf("project.describe.edit")) writes your own"))
            }
            if cursor, !meta(verdict).isEmpty { Text(meta(verdict)).font(Theme.text(11)).foregroundStyle(theme.inkFaint).fixedSize() }
            if !f.closed { ForestChats(f: f, cursor: cursor).fixedSize() }
            let prs = m.forestPRs(f)
            PRCell(numbers: prs.compactMap { $0.pr?.number }, state: prs.first?.pr.map(PRState.of),
                   signals: prs.first?.pr.flatMap { m.prSignals[$0.number] })
            // the forest's one step, in a column that never grows (round 29, P2): the full line is on hover
            StepText(step: f.closed ? "" : f.says, yours: f.move == .yours, here: cursor).help(f.says)
        }
        .frame(height: 30)
        .padding(.horizontal, 16)
        .rowChrome(RowKey.project(p.id), cursor: cursor, selected: selected)
    }

    private func meta(_ verdict: IntegrationVerdict?) -> String {
        if f.p.state == .archive || f.branches.isEmpty { return "" }
        var parts: [String] = []
        if f.unopened.count > 1 { parts.append("\(f.unopened.count) without a PR") }
        if verdict?.state == .clean { parts.append("merges clean") } else if verdict?.state == .conflicts { parts.append("doesn't merge") }
        if let t = f.p.ticket { parts.append(t) }
        let merging = f.branches.filter { $0.b.role != "proof" }
        parts.append("\(merging.filter { $0.st.ship == .landed }.count)/\(merging.count) landed")
        return parts.joined(separator: " · ")
    }
}

private struct BranchRowView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduced
    let v: BranchView
    let summary: String
    let cursor: Bool
    let selected: Bool

    var body: some View {
        let m = app.forestModel
        let armed = BranchCommands.isArmed(v.b.id, app)
        // gold means "you're acting here": the cursor row and anything in flight; merely ready reads brighter
        let live = v.b.pending != nil || armed
        let word = shipWord(m)
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(v.b.order < 999 ? "\(v.b.order)" : "").font(Theme.text(11)).foregroundStyle(theme.inkFaint).frame(width: 16, alignment: .trailing)
                .explains("branch|order|\(v.b.id)", RowName(word: "1 2 3", meaning: "the branch's place in merge order"))
            Text(leaf(v.b.name)).foregroundStyle(cursor ? theme.goldLeaf : theme.ink).lineLimit(1).frame(width: 172, alignment: .leading)
            Text(v.b.description == summary ? "" : v.b.description).foregroundStyle(theme.inkDim).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("\(v.b.role == "proof" ? "⚗" : v.st.ship.glyph) \(word)")
                .foregroundStyle(live ? theme.goldLeaf : v.st.ready ? theme.ink : theme.inkFaint)
                .opacity(v.b.pending != nil || word.hasSuffix("…") ? 0.75 : 1)
                .fixedSize()
                .settles("\(v.st.ship.rawValue)|\(word)", reduced: reduced)
                .explains("branch|ship|\(v.b.id)", shipTerm(word))
            if cursor, !meta.isEmpty {
                Text(meta).font(Theme.text(11)).foregroundStyle(v.b.gates == .red && v.pr == nil ? theme.del : theme.inkFaint).fixedSize()
            }
            if armed { Text(armHint).foregroundStyle(theme.goldLeaf).fixedSize() }
        }
        .frame(height: 32)
        .padding(.leading, 40).padding(.trailing, 16)
        .overlay { if armed { Rectangle().stroke(theme.goldDeep, lineWidth: 1) } }
        .rowChrome(RowKey.branch(v.b.id), cursor: cursor, selected: selected)
    }

    /// The stage's note, or the in-flight word's while one replaces it.
    private func shipTerm(_ word: String) -> RowName {
        switch word {
        case "pushing…": RowName(word: "pushing…", meaning: "sending it to origin")
        case "waiting for GitHub…": RowName(word: "waiting for GitHub…", meaning: "pushed with its PR opening; GitHub hasn't reported the PR yet")
        default: v.b.role == "proof" ? Self.proofTerm : v.st.ship.term
        }
    }

    /// stack-proof's branch: never a ship stage — it rides the forest for its run
    static let proofTerm = RowName(word: "⚗ proof", meaning: "a proof branch: it rides the forest for its e2e or smoke run and never merges")

    private func shipWord(_ m: ForestModel) -> String {
        if v.b.pending == "pushing" { return "pushing…" }
        return v.b.role == "proof" ? "proof" : v.st.ship.word
    }

    private var armHint: String {
        "\(app.registry.keyOf("branch.push")) again sends it to origin · \(app.registry.keyOf("overlay.close"))"
    }

    private var meta: String {
        let b = v.b
        var out: [String] = []
        if b.commits > 0 { out.append("\(b.commits) commit\(b.commits == 1 ? "" : "s")") }
        if b.pushed == .ahead { out.append("\(b.ahead) ahead of origin") }
        if v.pr == nil && b.gates != .green && b.commits > 0 {
            out.append(b.gates == .red ? "red: \(b.redGates.isEmpty ? "gates" : b.redGates.joined(separator: ", "))"
                       : b.gates == .running ? "gates running" : b.gates == .stale ? "gates stale" : "not gated")
        }
        if let h = b.holdUntil.flatMap(parseISO), v.pr == nil { out.append("held for \(PushWindow.fmtMorning(h))") }
        if v.st.ship == .approved, let w = v.st.waiting.first { out.append("waiting on \(w.label)") }
        return out.joined(separator: " · ")
    }
}

private struct LaunchLine: View {
    @Environment(\.theme) private var theme
    let f: ForestView

    var body: some View {
        let live = f.branches.filter { $0.st.ship != .landed }
        let done = live.filter { $0.pr != nil }.count
        HStack(spacing: 12) {
            Text("launch").foregroundStyle(theme.goldLeaf)
            ZStack(alignment: .leading) {
                Capsule().fill(theme.vellumEdge).frame(width: 112, height: 3)
                Capsule().fill(theme.goldLeaf).frame(width: 112 * CGFloat(done) / CGFloat(max(1, live.count)), height: 3)
            }
            if done < live.count { Text("\(done)/\(live.count) on GitHub").foregroundStyle(theme.inkDim) }
            else { Text("✦ all on GitHub").font(Theme.display(13)).foregroundStyle(theme.goldLeaf) }
        }
        .font(Theme.text(12))
        .padding(.leading, 40).padding(.vertical, 6)
    }
}
