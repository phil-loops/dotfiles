import CanopyCore
import SwiftUI

/// Forests.tsx, the home: every live forest grouped by whose move it is (focus first inside each), then the work
/// elsewhere and a quiet archive count (round 29). Each forest is one calm row that ↵ opens on its own page (the palette's "open or fold" unfolds its branch
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
                                // every live forest by whose move, focus first inside each; chats owed a reply and PRs awaiting your review are yours too
                                let groups = m.moveGroups()
                                ForEach(groups, id: \.move) { g in
                                    section(.focus, g.projects, fs, working, title: "\(g.move.title) · \(g.projects.count + (g.move == .yours ? m.replies().count : 0))", gold: g.move == .yours,
                                            nameWidth: nameWidth, cursor: cursor, selection: selection)
                                    if g.move == .yours { ReplyQueue(nameWidth: nameWidth, cursor: cursor, selection: selection); ReviewQueue(nameWidth: nameWidth, cursor: cursor, selection: selection) }
                                }
                                if !groups.contains(where: { $0.move == .yours }) { ReplyQueue(nameWidth: nameWidth, cursor: cursor, selection: selection); ReviewQueue(nameWidth: nameWidth, cursor: cursor, selection: selection) }
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
    private func section(_ state: ProjectState, _ projects: [Project], _ fs: [String: ForestView], _ working: [String: [TodoItem]], title: String? = nil, gold: Bool = false, nameWidth: CGFloat, cursor: String?, selection: Set<String>) -> some View {
        let m = app.forestModel
        let views = projects.compactMap { fs[$0.id] }.filter { !m.readyOnly || !$0.ready.isEmpty }
        if !m.readyOnly || !views.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                if let title {
                    Text(title).font(Theme.text(11)).foregroundStyle(gold ? theme.goldLeaf : theme.inkFaint)
                        .padding(.leading, 44).padding(.bottom, 4)
                } else if state != .focus {
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
                        Text("#\(r.number)").font(Theme.display(17)).foregroundStyle(here ? theme.goldLeaf : theme.ink)
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
            // the forest's one step, in a column that never grows (round 29, P2): the full line is on hover
            if !f.closed && !f.says.isEmpty {
                Text(f.says).font(Theme.text(11)).foregroundStyle(f.move == .yours ? theme.ink : theme.inkFaint)
                    .lineLimit(1).truncationMode(.tail).frame(width: 220, alignment: .trailing).help(f.says)
            }
            Color.clear.frame(width: 120, height: 1)
                .overlay(alignment: .leading) { if !f.closed { ForestChats(f: f, cursor: cursor) } }
            if cursor, !meta(verdict).isEmpty { Text(meta(verdict)).font(Theme.text(11)).foregroundStyle(theme.inkFaint).fixedSize() }
            if !f.closed && !f.branches.isEmpty {
                let merging = f.branches.filter { $0.b.role != "proof" }
                let landed = merging.filter { $0.st.ship == .landed }.count
                Text("\(landed)/\(merging.count)").font(Theme.text(11)).monospacedDigit().foregroundStyle(theme.inkFaint)
                    .frame(width: 40, alignment: .trailing)
                    .explains("forest|count|\(p.id)", RowName(word: "\(landed)/\(merging.count)", meaning: "branches landed of the branches it merges"))
            }
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
