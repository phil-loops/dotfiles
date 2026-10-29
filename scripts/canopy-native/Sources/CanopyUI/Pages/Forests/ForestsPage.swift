import CanopyCore
import SwiftUI

/// Placeholder for Forests.tsx: the focus lane then the workbench, one row per forest — the worked
/// example of a keyboard page: rows from the surface's pane, drawn by PaneList, j/k to move, ret
/// (pane.open → primary) to open.
struct ForestsPage: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    static func projects(_ s: Store) -> (focus: [Project], workbench: [Project]) {
        let all = s.list(Project.self)
        let byName: (Project, Project) -> Bool = { ($0.name, $0.repo) < ($1.name, $1.repo) }
        return (all.filter { $0.state == .focus }.sorted { ($0.rank ?? 0, $0.name) < ($1.rank ?? 0, $1.name) },
                all.filter { $0.state == .workbench }.sorted(by: byName))
    }

    var body: some View {
        let p = Self.projects(app.store)
        let focus = Set(p.focus.map(\.id))
        VStack(alignment: .leading, spacing: 6) {
            if !app.store.ready { Text("loading…").foregroundStyle(theme.inkFaint) }
            Text("placeholder — area: forests · j/k move · ret opens · v selects · : runs a command")
                .font(Theme.mono(11)).foregroundStyle(theme.inkFaint)
            PaneList(pane: "main", rows: (p.focus + p.workbench).map { RowKey.project($0.id) }) { key, on in
                let id = RowKey.id(key, "p") ?? ""
                if let project = app.store.view(Project.self, id) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(focus.contains(id) ? "◆" : "·").foregroundStyle(theme.goldDeep)
                        Text(project.name).foregroundStyle(on ? theme.goldLeaf : theme.ink)
                        Text("\(project.size)").foregroundStyle(theme.inkFaint)
                        Text(project.summary).foregroundStyle(theme.inkDim).lineLimit(1)
                    }
                }
            }
        }
        .padding(.horizontal, 16).padding(.bottom, 8)
    }
}
