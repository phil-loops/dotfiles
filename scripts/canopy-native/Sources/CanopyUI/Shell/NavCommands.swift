import CanopyCore
import Foundation

/// The navigation core's commands (NAV.md §4–§5): labels, the jumplist, the pickers, the goto
/// slots, search on the page. Owned by the shell.
@MainActor
enum NavCommands {
    static func install(_ app: AppModel) {
        let r = app.registry

        r.register(Command(id: "nav.labels", title: "Label everything on screen — type a label to go there", scope: .global,
                           verb: .labels, modes: [.normal, .select], label: "labels",
                           local: { [weak app] _, _ in try app?.showLabels() }))
        installHistory(app)
        installPickers(app)
    }
}

extension NavCommands {
    static func installHistory(_ app: AppModel) {
        let r = app.registry
        r.register(Command(id: "nav.save", title: "Save this spot to the jumplist", scope: .global, verb: .saveJump, modes: [.normal, .select], label: "save",
                           local: { [weak app] _, _ in
                               guard let app else { return }
                               app.jumps.save(app.here())
                               app.runner.say("saved · C-o comes back here")
                           }))
        r.register(Command(id: "nav.alternate", title: "Go to the alternate place (where the last jump left from)", scope: .global, verb: .alternate,
                           label: "alternate",
                           available: { [weak app] _ in app?.jumps.alternate != nil },
                           local: { [weak app] _, _ in if app?.jumpAlternate() != true { throw Refusal("you're already there") } }))
    }
}
