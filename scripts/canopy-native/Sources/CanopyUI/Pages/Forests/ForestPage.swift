import CanopyCore
import SwiftUI

/// Forest.tsx: one forest's page (/v2/p/<repo>/<project>) — every branch in merge order with what it
/// does in full (its description and commit outline) and where it stands (ship state, gates, PR, open
/// threads). `l` opens a branch's review page, `h` goes back to Forests, `tab` turns to the story.
struct ForestPage: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduced
    let route: Route

    var body: some View {
        let m = app.forestModel
        let pid = m.pageProject
        Group {
            if !app.store.ready {
                Text("reading the forest…").foregroundStyle(theme.inkFaint).padding(.leading, 44)
            } else if let pid, let p = app.store.view(Project.self, pid), let f = m.forest(pid) {
                page(p, f)
            } else {
                Text("no such forest").foregroundStyle(theme.inkFaint).padding(.leading, 44)
            }
        }
        .padding(.horizontal, 16).padding(.bottom, 8)
        .onChange(of: app.keys.mode) { from, _ in
            // esc out of insert drops the description being typed
            if from == .insert && m.describing != nil { m.describing = nil }
        }
    }

    private func page(_ p: Project, _ f: ForestView) -> some View {
        let m = app.forestModel
        let rows = m.forestRows(p.id)
        let focused = app.isFocused("main")
        let cursor = focused ? app.selected : nil
        let selection = focused ? Set(app.selection) : []
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header(p, f)
                    if m.face == .story {
                        StoryView(pid: p.id, cursor: cursor, selection: selection)
                    } else {
                        ForEach(f.branches, id: \.b.id) { v in
                            ForestBranchView(v: v, cursor: cursor == RowKey.branch(v.b.id), selected: selection.contains(RowKey.branch(v.b.id)))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .glides(rows, reduced: reduced)
            }
            .labelPane("main")
            .onChange(of: cursor) { _, k in if let k { proxy.scrollTo(k) } }
        }
        // does every branch merge onto main at once — asked when the page opens and whenever a tip moves
        .task(id: m.integratable(p.id) ? m.stampOf(p.id) : "") {
            if m.integratable(p.id) { await m.checkIntegration(p.id) }
        }
    }

    private func header(_ p: Project, _ f: ForestView) -> some View {
        let m = app.forestModel
        let by = { (s: ShipStage) in f.branches.filter { $0.st.ship == s }.count }
        let counts = ["\(f.branches.count) branch\(f.branches.count == 1 ? "" : "es")",
                      by(.landed) > 0 ? "\(by(.landed)) landed" : "", f.ready.isEmpty ? "" : "\(f.ready.count) ready"]
            .filter { !$0.isEmpty }.joined(separator: " · ")
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(p.name).font(Theme.display(26)).foregroundStyle(theme.ink)
                if let t = p.ticket { Text(t).font(Theme.mono(12)).foregroundStyle(theme.inkFaint) }
                Spacer()
                faceTabs
            }
            if !p.summary.isEmpty { Text(p.summary).foregroundStyle(theme.inkDim) }
            HStack(spacing: 0) {
                Text("\(p.state.rawValue) · \(counts)").foregroundStyle(theme.inkFaint)
                if m.integratable(p.id), let v = m.verdict(p.id) {
                    Text(" · ").foregroundStyle(theme.inkFaint)
                    Button(Self.merge[v.state]!) { app.runner.dispatch("forest.integrate", via: .click, target: p.id) }
                        .buttonStyle(.plain)
                        .foregroundStyle(v.state == .conflicts ? theme.del : theme.inkFaint)
                        .opacity(v.state == .checking ? 0.7 : 1)
                        .labelTarget(pane: "controls", key: "forest.integrate", title: "merge check", run: RouteTo("forest.integrate", target: p.id))
                        .help(v.state == .conflicts ? "the branches don't merge onto main together\n\(v.detail)" : v.state == .clean ? "every branch merged onto main at once, cleanly" : v.detail)
                }
            }
            .font(Theme.mono(12))
            if let v = m.verdict(p.id), v.state == .conflicts, !v.detail.isEmpty {
                // the leaves that conflict, on the page itself — never only in a tooltip
                Text(v.detail).font(Theme.mono(11)).foregroundStyle(theme.del.opacity(0.8)).lineLimit(3)
            }
        }
        .padding(.leading, 52).padding(.trailing, 20).padding(.top, 4).padding(.bottom, 20)
    }

    private var faceTabs: some View {
        let face = app.forestModel.face
        return HStack(spacing: 8) {
            Text("branches").foregroundStyle(face == .branches ? theme.goldLeaf : theme.inkFaint)
            Text("story").foregroundStyle(face == .story ? theme.goldLeaf : theme.inkFaint)
            KeyHint(id: "forest.face")
        }
        .font(Theme.mono(11))
        .contentShape(Rectangle())
        .onTapGesture { app.runner.dispatch("forest.face", via: .click) }
        .labelTarget(pane: "controls", key: "forest.face", title: face == .story ? "branches" : "story", run: RouteTo("forest.face"))
    }

    static let merge: [IntegrationVerdict.State: String] = [
        .checking: "◌ merging…", .clean: "✓ merges clean", .conflicts: "✕ doesn't merge", .failed: "merge check couldn't run",
    ]
}

/// One branch on the forest page: name, its keys when the cursor's on it, the description (or the
/// field typing it), the outline or the full commits, the loop strip and its PR facts.
private struct ForestBranchView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    let v: BranchView
    let cursor: Bool
    let selected: Bool

    var body: some View {
        @Bindable var m = app.forestModel
        let b = v.b
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(b.order < 999 ? "\(b.order)" : "").font(Theme.mono(11)).foregroundStyle(theme.inkFaint).frame(width: 20, alignment: .trailing)
                Text(leaf(b.name)).font(Theme.display(17)).foregroundStyle(cursor ? theme.goldLeaf : theme.ink).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !facts.isEmpty { Text(facts.joined(separator: "  ")).font(Theme.mono(11)).foregroundStyle(theme.inkFaint).fixedSize() }
                LoopStripView(branchID: b.id, size: 11).fixedSize()
            }
            VStack(alignment: .leading, spacing: 6) {
                if m.describing == b.id {
                    ModalTextField(BranchCommands.describeField, prompt: "one line: what the branch does", text: $m.draft)
                        .foregroundStyle(theme.ink)
                        .padding(4)
                        .background(theme.vellumRaise)
                    Text("\(app.registry.keyOf("branch.describe.save")) saves · esc leaves it").font(Theme.mono(11)).foregroundStyle(theme.inkFaint)
                } else {
                    Text(b.description.isEmpty ? "no description" : b.description)
                        .foregroundStyle(b.description.isEmpty ? theme.inkFaint : theme.inkDim)
                        .italic(b.description.isEmpty)
                        .lineLimit(1)
                }
                if m.wordsOpen.contains(b.id) {
                    CommitWords(branchID: b.id).font(Theme.mono(12))
                }
            }
            .padding(.leading, 32)
        }
        .padding(.vertical, 9).padding(.leading, 20).padding(.trailing, 20)
        .opacity(v.st.ship == .landed ? 0.6 : 1)
        .rowChrome(RowKey.branch(b.id), cursor: cursor, selected: selected)
    }

    private var facts: [String] {
        var out: [String] = []
        if let pr = v.pr { out.append("#\(pr.number)\((pr.approvals ?? 0) > 0 ? " · \(pr.approvals!) approval\(pr.approvals == 1 ? "" : "s")" : "")") }
        let n = app.store.list(CanopyCore.Thread.self).filter { $0.repo == v.b.repo && $0.branch == v.b.name && !$0.resolved && !$0.outdated }.count
        if n > 0 { out.append("\(n) open") }
        return out
    }
}
