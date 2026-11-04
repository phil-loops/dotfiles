import AppKit
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
        r.register(Command(id: "nav.link", title: "Copy a link to here — canopy opens it at this spot", scope: .global, verb: .copy, label: "link",
                           local: { [weak app] _, _ in
                               guard let app else { return }
                               let link = app.here().shared.link
                               Clipboard.copy(link)
                               app.runner.say("copied \(link)")
                           }))
        r.register(Command(id: "nav.place", title: "Copy where you are, in words — the page, the file and line, then the link",
                           scope: .global, verb: .copyPlace, label: "copy place",
                           local: { [weak app] _, _ in
                               guard let app else { return }
                               let text = placeInWords(app)
                               Clipboard.copy(text)
                               app.runner.say("copied \(text.split(separator: "\n").first ?? "")")
                           }))
        r.register(Command(id: "nav.alternate", title: "Go to the alternate place (where the last jump left from)", scope: .global, verb: .alternate,
                           label: "alternate",
                           available: { [weak app] _ in app?.jumps.alternate != nil },
                           local: { [weak app] _, _ in if app?.jumpAlternate() != true { throw Refusal("you're already there") } }))
    }
}

extension NavCommands {
    /// Where you are, for a person or a session reading it: the breadcrumb (a branch's description
    /// after it), the file and line when there's one, then the canopy link that opens it.
    @MainActor static func placeInWords(_ app: AppModel) -> String {
        let place = app.here().shared
        var head = (app.provider?.crumbs(app, route: place.route) ?? []).map(\.title).joined(separator: " › ")
        if case let .review(repo, branch, _) = place.route,
           let d = app.store.view(Branch.self, "\(repo):\(branch)")?.description, !d.isEmpty {
            head += (head.isEmpty ? "" : " — ") + d
        }
        let q = URLComponents(string: place.link)?.queryItems ?? []
        let file = q.first { $0.name == "file" }?.value
        let line = q.first { $0.name == "line" }?.value
        return [head.isEmpty ? nil : head, file.map { f in line.map { "\(f):\($0)" } ?? f }, place.link]
            .compactMap { $0 }.joined(separator: "\n")
    }
}
