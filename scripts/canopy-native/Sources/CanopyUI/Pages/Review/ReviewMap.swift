import CanopyCore
import SwiftUI

/// The forest map over the review page (`space m`, Overlays.tsx MapOverlay): the forest's branches
/// in merge order, indented by ancestry, then the other PRs; j/k walk it, ↵ opens, p the forest's page.
@MainActor
enum ReviewMap {
    struct Row: Equatable { var id: String; var label: String; var depth: Int; var word: String; var threads: Int }

    static let words: [ShipStage: String] = [.local: "local", .green: "green", .pushed: "pushed", .review: "in review", .approved: "approved", .landed: "landed"]

    static func rows(_ app: AppModel) -> [Row] {
        let pg = ReviewPageState.of(app)
        let here = pg.id
        let threads = app.store.table(CanopyCore.Thread.self).values
        func open(_ id: String) -> Int { threads.filter { "\($0.repo):\($0.branch)" == id && !$0.resolved && !$0.outdated }.count }
        var out: [Row] = []
        let b = app.store.view(Branch.self, here)
        if let b {
            func depth(_ id: String?, _ n: Int = 0) -> Int {
                guard let id, let p = app.store.view(Branch.self, id), n < 32 else { return n }
                return depth(p.parentId, n + 1)
            }
            for x in app.store.list(Branch.self).filter({ $0.project == b.project }).sorted(by: { ($0.order, $0.name) < ($1.order, $1.name) }) {
                let ship = ShipRules.shipOf(x, app.store.view(Pr.self, x.id))
                if ship == .landed { continue }
                out.append(Row(id: x.id, label: x.name, depth: depth(x.parentId), word: words[ship] ?? "", threads: open(x.id)))
            }
        }
        for c in app.store.list(Conv.self) where !out.contains(where: { $0.id == c.id }) {
            if let b, app.store.view(Branch.self, c.id)?.project == b.project { continue }
            out.append(Row(id: c.id, label: "#\(c.number) \(c.title)", depth: 0, word: c.author == c.viewer ? "yours" : "@\(c.author)", threads: open(c.id)))
        }
        return out
    }
}

struct MapOverlay: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        let pg = ReviewPageState.of(app)
        let rows = ReviewMap.rows(app)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("forest").foregroundStyle(theme.goldLeaf)
                Spacer()
                Text("j/k · ↵ open · p page · esc").foregroundStyle(theme.inkFaint)
            }
            .font(Theme.text(11)).padding(.bottom, 6)
            if rows.isEmpty { Text("nothing else").foregroundStyle(theme.inkFaint) }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { i, r in
                            HStack(spacing: 8) {
                                Text((r.depth > 0 ? "└ " : "") + shortPath(r.label)).lineLimit(1)
                                    .foregroundStyle(r.id == pg.id ? theme.goldLeaf : theme.ink)
                                Spacer()
                                if r.threads > 0 { Text("\(r.threads)").foregroundStyle(theme.ember) }
                                Text(r.word).foregroundStyle(theme.inkFaint)
                            }
                            .padding(.leading, CGFloat(r.depth) * 16 + 6).padding(.vertical, 3).padding(.trailing, 6)
                            .background(i == pg.mapIndex ? theme.goldWash : .clear)
                            .overlay(alignment: .leading) { if i == pg.mapIndex { theme.goldLeaf.frame(width: 2) } }
                            .id(i)
                            .labelTarget(pane: "map", key: r.id, title: r.label, run: RouteTo("review.map.go", arg: r.id))
                        }
                    }
                }
                .onChange(of: pg.mapIndex) { _, i in proxy.scrollTo(i) }
            }
        }
        .font(Theme.text(12))
        .padding(14)
        .frame(width: 520)
        .frame(maxHeight: 520)
        .background(theme.vellumRaise)
        .overlay { Rectangle().stroke(theme.goldDeep, lineWidth: 1) }
    }
}
