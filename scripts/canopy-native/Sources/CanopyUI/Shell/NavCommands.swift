import CanopyCore
import Foundation

/// The navigation core's commands (NAV.md §4–§5): labels, the jumplist, the pickers, the goto
/// slots, search on the page. Owned by the shell.
@MainActor
enum NavCommands {
    static func install(_ app: AppModel) {
        let r = app.registry

        r.register(Command(id: "nav.labels", title: "Label everything on screen — type a label to go there", scope: .global,
                           keys: ["g w", "f"], modes: [.normal, .select], label: "labels",
                           local: { [weak app] _, _ in try app?.showLabels() }))
    }
}
