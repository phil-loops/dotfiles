import CanopyCore
import SwiftUI

/// Placeholder for Forest.tsx + Story.tsx: one forest's branches in merge order; ret opens one.
struct ForestPage: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    let route: Route

    static func branches(_ s: Store, _ route: Route) -> [Branch] {
        let id = route.projectID ?? ""
        return s.list(Branch.self).filter { $0.project == id }.sorted { ($0.order, $0.name) < ($1.order, $1.name) }
    }

    var body: some View {
        let bs = Self.branches(app.store, route)
        VStack(alignment: .leading, spacing: 6) {
            Text(app.store.view(Project.self, route.projectID ?? "")?.name ?? "no such forest").font(Theme.display(22)).foregroundStyle(theme.goldLeaf)
            Text("placeholder — area: forests · ports Forest.tsx, Story.tsx, LoopStrip.tsx, loop.ts, ship.ts, integrate.ts, drag.ts, commands/project.ts, commands/branch.ts")
                .font(Theme.mono(11)).foregroundStyle(theme.inkFaint)
            PaneList(pane: "main", rows: bs.map { RowKey.branch($0.id) }) { key, on in
                if let b = app.store.view(Branch.self, RowKey.id(key, "b") ?? "") {
                    HStack(spacing: 10) {
                        Text("\(b.order).").foregroundStyle(theme.inkFaint)
                        Text(b.name).foregroundStyle(on ? theme.goldLeaf : theme.ink)
                        Text("gates \(b.gates.rawValue) · \(b.pushed.rawValue)").foregroundStyle(theme.inkDim)
                    }
                }
            }
        }
        .padding(.horizontal, 16).padding(.bottom, 8)
    }
}
