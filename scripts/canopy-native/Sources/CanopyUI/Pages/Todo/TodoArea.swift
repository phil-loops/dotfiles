import CanopyCore
import SwiftUI

/// The tracker (/v2/todo): the `todo` store domain (srv/todo.py, ~/.dotfiles/canopy/todo) — the
/// viewer's own feature queue, or a forest's todo list (`, p` switches). Needs you → doing → the
/// ranked queue → waiting.
enum TodoArea: PageArea {
    static let name = "todo"
    static func install(_ app: AppModel) {
        app.addSurface(TodoSurface())
        TodoCommands.install(app)
    }
}

struct TodoSurface: SurfaceProvider {
    let surfaceID = "todo"

    func view(_ app: AppModel, route: Route) -> AnyView { AnyView(TodoPage()) }

    /// model.ts rows on the tracker: its items, section by section.
    func rows(_ app: AppModel) -> [String] {
        let list = app.state { TrackerUI() }.list
        return Tracker.queue(app.store.trackerItems(on: list)).flatMap { $0.items.map { RowKey.todo($0.id) } }
    }

    func panes(_ app: AppModel) -> [Pane] { [Pane(id: "main", title: "tracker", rows: rows(app))] }

    func primary(for row: String, _ app: AppModel) -> RouteTo? {
        RowKey.id(row, "t").map { RouteTo("todo.open", target: $0) }
    }

    func scopes(_ app: AppModel) -> [Scope] {
        target(for: .item, app) != nil ? [.item, .todo] : [.todo]
    }

    func target(for scope: Scope, _ app: AppModel) -> String? {
        if scope == .todo { return "tracker" }
        guard scope == .item, let id = RowKey.id(app.selected, "t"), app.store.trackerItem(id) != nil else { return nil }
        return id
    }
}

private let KIND = ["build": "build", "fix": "fix", "decide": "decide", "look": "look into"]

/// Todo.tsx: an item per row (rank, title, kind · area · size); the cursor row says why (or what
/// it waits on); `ret` unfolds its notes.
struct TodoPage: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        let list = app.state { TrackerUI() }.list
        let sections = Tracker.queue(app.store.trackerItems(on: list))
        let open = sections.reduce(0) { $0 + $1.items.count }
        if !app.store.ready {
            Text("reading the tracker…").foregroundStyle(theme.inkFaint).padding(.horizontal, 44)
        } else {
            FollowScroll(panes: ["main"]) {
                VStack(alignment: .leading, spacing: 0) {
                    heading(list, open).foregroundStyle(theme.inkDim).padding(.leading, 44).padding(.bottom, 20)
                    if sections.isEmpty { Text("nothing tracked").foregroundStyle(theme.inkFaint).padding(.leading, 44) }
                    ForEach(sections, id: \.section) { s in
                        VStack(alignment: .leading, spacing: 0) {
                            SectionHead(text: "\(Tracker.titles[s.section]!) · \(s.items.count)", gold: s.section == .decide)
                                .padding(.leading, 44).padding(.bottom, 4)
                            ForEach(s.items, id: \.id) { t in TodoRow(t: t) }
                        }
                        .padding(.bottom, 26)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .paneRing("main")
            .padding(.horizontal, 16).padding(.bottom, 8)
        }
    }

    private func heading(_ list: String?, _ open: Int) -> Text {
        guard let list else { return Text("\(open) open · ") + Text("/next").foregroundColor(theme.inkFaint) + Text(" ranks") }
        return Text(app.store.view(Project.self, list)?.name ?? list).foregroundColor(theme.ink) + Text(" · \(open) open")
    }
}

struct TodoRow: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    let t: TodoItem

    var body: some View {
        let ui = app.state { TrackerUI() }
        let open = ui.open.contains(t.id)
        CursorRow(pane: "main", key: RowKey.todo(t.id)) { on in
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(t.rank.map(String.init) ?? "").font(Theme.text(11)).foregroundStyle(theme.inkFaint).frame(width: 28, alignment: .trailing)
                    HStack(spacing: 8) {
                        Text(t.title).font(Theme.display(17)).foregroundStyle(on ? theme.goldLeaf : theme.ink).lineLimit(1)
                        if !(t.problems ?? []).isEmpty { Text("⚠").font(Theme.text(12)).foregroundStyle(theme.ember) }
                    }
                    Spacer(minLength: 8)
                    Text("\(KIND[t.kind] ?? t.kind) · \(t.area) · \(t.size)").font(Theme.text(11)).foregroundStyle(theme.inkFaint)
                }
                .frame(minHeight: 34)
                .padding(.leading, 28).padding(.trailing, 16)
                if on && !open {
                    let line = t.state == "waiting" ? "⏳ \(t.waiting ?? "")" : !(t.problems ?? []).isEmpty ? t.problems!.joined(separator: " · ") : t.why
                    if !line.isEmpty {
                        Text(line).font(Theme.text(12.5)).foregroundStyle(t.state == "broken" ? theme.ember : theme.inkDim)
                            .padding(.leading, 68).padding(.trailing, 16).padding(.bottom, 8)
                    }
                }
            }
        }
        if open { notes }
    }

    private var notes: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !t.why.isEmpty { Text(t.why).foregroundStyle(theme.ink) }
            if let p = t.problems, !p.isEmpty { Text(p.joined(separator: " · ")).foregroundStyle(theme.ember) }
            if let b = t.blocked_by, !b.isEmpty { Text("after: \(b.joined(separator: ", "))") }
            if !t.body.isEmpty { MarkdownView(t.body, size: 13) }
            if let l = t.links, !l.isEmpty { Text(l.joined(separator: " · ")).foregroundStyle(theme.inkFaint) }
            Text("\(t.id) · since \(t.created ?? "?") · /next \(t.id)").font(Theme.text(11)).foregroundStyle(theme.inkFaint)
        }
        .font(Theme.text(13))
        .foregroundStyle(theme.inkDim)
        .textSelection(.enabled)
        .padding(.leading, 16)
        .overlay(alignment: .leading) { theme.rule.frame(width: 1) }
        .padding(.leading, 86).padding(.trailing, 16).padding(.bottom, 12)
    }
}
