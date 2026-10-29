import CanopyCore
import SwiftUI

/// The tracker (/v2/todo): the viewer's own feature queue from the `todo` store domain.
enum TodoArea: PageArea {
    static let name = "todo"
    static func install(_ app: AppModel) { app.addSurface(TodoSurface()) }
}

struct TodoSurface: PlaceholderSurface {
    let surfaceID = "todo"
    func placeholder(_ app: AppModel, route: Route) -> Placeholder {
        let open = app.store.list(TodoItem.self).filter { $0.state != .done && $0.state != .dropped }.sorted { ($0.rank ?? .max, $0.id) < ($1.rank ?? .max, $1.id) }
        return Placeholder(title: "Todo", area: "todo", sources: ["Todo.tsx", "tracker.ts", "commands/todo.ts"],
                           notes: open.map { "\($0.state.rawValue) · \($0.title)" })
    }
}
