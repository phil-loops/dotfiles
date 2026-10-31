import CanopyCore
import SwiftUI

/// Forests.tsx, the home: focus (hand-ordered), the workbench, and a quiet archive count. Each forest
/// is one calm row that opens inline into its branch spine, in merge order; each branch says where it
/// stands in one glyph and word and does one thing on ↵. `, r` narrows it all to what's ready.
struct ForestsPage: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduced

    var body: some View {
        let m = app.forestModel
        let p = m.projects()
        let fs = m.forests()
        let rows = m.homeRows()
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
                            }
                            section("Focus", p.focus, fs, nameWidth: nameWidth, cursor: cursor, selection: selection)
                            section("Workbench", p.workbench, fs, nameWidth: nameWidth, cursor: cursor, selection: selection)
                            if !m.readyOnly {
                                if m.showArchive {
                                    section("Archive", p.archive, fs, nameWidth: nameWidth, cursor: cursor, selection: selection)
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
                    .onChange(of: cursor) { _, k in if let k { proxy.scrollTo(k) } }
                }
            }
        }
        .padding(.horizontal, 16).padding(.bottom, 8)
        .onChange(of: m.closedIDs(), initial: true) { _, _ in m.syncClosings() }
        .task { await tick(m) }
        // the cursor landing on a branch warms its review page's diff (Forests.tsx warmSelected)
        .onChange(of: cursor, initial: true) { _, k in
            if let b = RowKey.id(k, "b").flatMap({ app.store.view(Branch.self, $0) }) { ReviewPageState.of(app).warm(repo: b.repo, name: b.name, at: b.tip) }
        }
        // the cursor resting on a forest asks whether it merges — a second of git, so only the one you stop on
        .task(id: cursor) {
            guard let pid = RowKey.id(cursor, "p") else { return }
            try? await Task.sleep(nanoseconds: 700_000_000)
            if !Task.isCancelled { await m.checkIntegration(pid) }
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ projects: [Project], _ fs: [String: ForestView], nameWidth: CGFloat, cursor: String?, selection: Set<String>) -> some View {
        let m = app.forestModel
        let views = projects.compactMap { fs[$0.id] }.filter { !m.readyOnly || !$0.ready.isEmpty }
        if !m.readyOnly || !views.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text(title.uppercased()).font(Theme.text(11)).tracking(1.5).foregroundStyle(theme.inkFaint)
                    .padding(.leading, 44).padding(.bottom, 4)
                if views.isEmpty {
                    Text("empty").foregroundStyle(theme.inkFaint).padding(.leading, 44).padding(.vertical, 8)
                }
                ForEach(views, id: \.p.id) { f in
                    ForestRowView(f: f, nameWidth: nameWidth, cursor: cursor == RowKey.project(f.p.id), selected: selection.contains(RowKey.project(f.p.id)))
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

    private func tick(_ m: ForestModel) async {
        while !Task.isCancelled {
            m.now = Date()
            try? await Task.sleep(nanoseconds: 30_000_000_000)
        }
    }
}

/// The push window's one line, and the holds that came due overnight.
private struct WindowLine: View {
    @Environment(\.theme) private var theme
    let fs: [String: ForestView]
    let now: Date

    var body: some View {
        let due = fs.values.flatMap(\.branches).filter { v in v.pr == nil && (v.b.holdUntil.flatMap(parseISO).map { $0 <= now } ?? false) }.count
        let text = PushWindow.line(now)
        let phase = PushWindow.phaseAt(now).phase
        if !text.isEmpty || due > 0 {
            (Text(text).foregroundColor(phase == .late || phase == .weekend ? theme.ember : theme.goldLeaf)
                + Text(due > 0 ? "\(text.isEmpty ? "" : " · ")☀ \(due) held overnight \(due == 1 ? "is" : "are") due" : "").foregroundColor(theme.goldLeaf))
                .font(Theme.display(15))
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
        let m = app.forestModel
        let p = f.p
        let closing = m.closing.contains(p.id)
        let verdict = m.verdict(p.id)
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            // the focus lane reorders by key (C-k / C-j); the grip only says it can
            Text("⋮").foregroundStyle(theme.inkFaint).opacity(p.state == .focus && cursor ? 1 : 0).frame(width: 12)
            HStack(spacing: 6) {
                Text(p.name).font(Theme.display(17))
                    .foregroundStyle(cursor ? theme.goldLeaf : f.closed ? theme.inkFaint : theme.ink)
                    .lineLimit(1).truncationMode(.tail)
                if verdict?.state == .conflicts { Text("✕").font(Theme.text(11)).foregroundStyle(theme.del) }
            }
            .frame(width: nameWidth, alignment: .leading)
            if closing || f.closed {
                Text("✦ canopy closed").font(Theme.display(13)).foregroundStyle(closing ? theme.goldLeaf.opacity(0.8) : theme.inkFaint)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(p.summary).foregroundStyle(theme.inkDim).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            }
            if cursor, !meta(verdict).isEmpty { Text(meta(verdict)).font(Theme.text(11)).foregroundStyle(theme.inkFaint).fixedSize() }
            if !f.closed && !f.branches.isEmpty {
                // one dot per branch in merge order: landed, ready to act on, still in the works
                HStack(spacing: 4) {
                    ForEach(f.branches, id: \.b.id) { v in
                        Circle().fill(v.st.ship == .landed ? theme.patina : v.st.ready ? theme.goldLeaf : theme.inkFaint.opacity(0.45))
                            .frame(width: 6, height: 6)
                    }
                }
                .frame(minWidth: 60, alignment: .trailing)
            }
        }
        .frame(height: 38)
        .padding(.horizontal, 16)
        .rowChrome(RowKey.project(p.id), cursor: cursor, selected: selected)
    }

    private var hint: String {
        let go = app.registry.keyOf("row.primary")
        if f.p.state == .archive { return "\(go) restore" }
        if f.closed { return "\(go) archive" }
        if f.branches.isEmpty || app.forestModel.readyOnly { return "" }
        return "\(go) page" + (f.unopened.count > 1 ? " · \(app.registry.keyOf("forest.launch")) launch all" : "")
    }

    private func meta(_ verdict: IntegrationVerdict?) -> String {
        if f.p.state == .archive || f.branches.isEmpty { return "" }
        var parts = ["\(f.branches.count) branch\(f.branches.count == 1 ? "" : "es")"]
        if !f.ready.isEmpty { parts.append("\(f.ready.count) ready") }
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
        let armed = m.armed == v.b.id
        // gold means "you're acting here": the cursor row and anything in flight; merely ready reads brighter
        let live = v.b.pending != nil || armed
        let word = shipWord(m)
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(v.b.order < 999 ? "\(v.b.order)" : "").font(Theme.text(11)).foregroundStyle(theme.inkFaint).frame(width: 16, alignment: .trailing)
            Text(leaf(v.b.name)).foregroundStyle(cursor ? theme.goldLeaf : theme.ink).lineLimit(1).frame(width: 172, alignment: .leading)
            Text(v.b.description == summary ? "" : v.b.description).foregroundStyle(theme.inkDim).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("\(v.st.ship.glyph) \(word)")
                .foregroundStyle(live ? theme.goldLeaf : v.st.ready ? theme.ink : theme.inkFaint)
                .opacity(v.b.pending != nil || word.hasSuffix("…") ? 0.75 : 1)
                .fixedSize()
                .settles("\(v.st.ship.rawValue)|\(word)", reduced: reduced)
            if cursor, !meta.isEmpty {
                Text(meta).font(Theme.text(11)).foregroundStyle(v.b.gates == .red && v.pr == nil ? theme.del : theme.inkFaint).fixedSize()
            }
            if m.armed == v.b.id { Text(hint(m)).foregroundStyle(theme.goldLeaf).fixedSize() }
        }
        .frame(height: 32)
        .padding(.leading, 40).padding(.trailing, 16)
        .overlay { if armed { Rectangle().stroke(theme.goldDeep, lineWidth: 1) } }
        .rowChrome(RowKey.branch(v.b.id), cursor: cursor, selected: selected)
    }

    private func shipWord(_ m: ForestModel) -> String {
        if v.b.pending == "pushing" { return "pushing…" }
        if v.st.ship == .pushed && m.opened.contains(v.b.id) { return "waiting for GitHub…" }
        return v.st.ship.word
    }

    private func hint(_ m: ForestModel) -> String {
        let go = app.registry.keyOf("row.primary")
        if m.armed == v.b.id { return "\(go) again sends it to origin · \(app.registry.keyOf("overlay.close"))" }
        if v.b.pending != nil { return "" }
        switch v.st.action {
        case .push: return "\(go) push"
        case .pr: return v.pr.map { "\(go) view #\($0.number)" } ?? "\(go) open PR"
        default: return "\(go) open"
        }
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
