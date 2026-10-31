import CanopyCore
import SwiftUI

/// Story.tsx: a forest's story (the forest page's other face, `tab`) — the feature told top to bottom:
/// every chapter in merge order, what already landed included, then what's in flight, then what's
/// left. One plain line each; `e` opens a chapter's why (a landed PR's squash message on main, a
/// live branch's commit messages), `ret` a live chapter's review page.
struct StoryView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    let pid: String
    let cursor: String?
    let selection: Set<String>

    var body: some View {
        let m = app.forestModel
        let s = m.story(pid)
        VStack(alignment: .leading, spacing: 0) {
            if !s.landed.isEmpty {
                heading("Landed", s.landed.count)
                ForEach(Array(s.landed.enumerated()), id: \.element.id) { i, l in
                    let k = RowKey.landed(l.id)
                    Chapter(n: i + 1, key: k, line: OutlineHints.bare(l.title), side: "#\(l.pr) · merged \(StoryText.day(l.at))", dim: true,
                            cursor: cursor == k, selected: selection.contains(k)) {
                        if m.wordsOpen.contains(k) { LandedWhy(l: l) }
                    }
                }
            }
            if !s.inFlight.isEmpty {
                heading("In flight", s.inFlight.count)
                ForEach(Array(s.inFlight.enumerated()), id: \.element.b.id) { i, v in live(v, s.landed.count + i + 1) }
            }
            if !s.left.isEmpty {
                heading("Left", s.left.count)
                ForEach(Array(s.left.enumerated()), id: \.element.b.id) { i, v in live(v, s.landed.count + s.inFlight.count + i + 1) }
            }
        }
    }

    private func live(_ v: BranchView, _ n: Int) -> some View {
        let k = RowKey.branch(v.b.id)
        let side = [v.pr.map { "#\($0.number)" } ?? "", v.st.ship.word].filter { !$0.isEmpty }.joined(separator: " · ")
        return Chapter(n: n, key: k, line: v.b.description.isEmpty ? leaf(v.b.name) : v.b.description, side: side, dim: false,
                       cursor: cursor == k, selected: selection.contains(k)) {
            if app.forestModel.wordsOpen.contains(v.b.id) { CommitWords(branchID: v.b.id) }
        }
    }

    private func heading(_ title: String, _ n: Int) -> some View {
        Text("\(title.uppercased()) · \(n)").font(Theme.mono(11)).tracking(1.5).foregroundStyle(theme.inkFaint)
            .padding(.leading, 44).padding(.top, 24).padding(.bottom, 4)
    }
}

private struct Chapter<Extra: View>: View {
    @Environment(\.theme) private var theme
    let n: Int
    let key: String
    let line: String
    let side: String
    let dim: Bool
    let cursor: Bool
    let selected: Bool
    @ViewBuilder let extra: () -> Extra

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("\(n)").font(Theme.mono(11)).foregroundStyle(theme.inkFaint).frame(width: 20, alignment: .trailing)
                Text(line).foregroundStyle(cursor ? theme.goldLeaf : dim ? theme.inkDim : theme.ink).frame(maxWidth: .infinity, alignment: .leading)
                Text(side).font(Theme.mono(11)).foregroundStyle(theme.inkFaint).fixedSize()
            }
            extra().font(Theme.mono(12)).padding(.leading, 32)
        }
        .padding(.vertical, 8).padding(.leading, 40).padding(.trailing, 16)
        .rowChrome(key, cursor: cursor, selected: selected)
    }
}

/// A landed chapter's why: the squash commit's message on main (GET /landed-why), plan stripped.
private struct LandedWhy: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    let l: Landed
    @State private var body_: String?
    @State private var loading = true

    struct Answer: Decodable { var subject: String; var body: String }

    var body: some View {
        Group {
            if let b = body_ {
                Text(OutlineHints.stripPlan(b).isEmpty ? "no body" : OutlineHints.stripPlan(b)).foregroundStyle(theme.inkDim)
            } else {
                Text(loading ? "reading main…" : "not on main yet").foregroundStyle(theme.inkFaint)
            }
        }
        .task(id: l.id) {
            loading = true
            let t = app.transport
            body_ = (try? await t.getJSON(t.atRepo(l.repo, "/landed-why?pr=\(l.pr)"), as: Answer.self))?.body
            loading = false
        }
    }
}

/// How the story prints a merge day.
enum StoryText {
    /// "Jun 23".
    static func day(_ iso: String) -> String {
        guard let d = parseISO(iso) else { return iso }
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMd")
        return f.string(from: d)
    }
}
