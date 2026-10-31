import CanopyCore
import Foundation

/// The commands every surface has (commands/app.ts + commands/nav.ts, extended app-wide with the
/// modal grammar): modes, the `:` line, the layers, motion through the focused pane (j/k, gg/G,
/// C-d/C-u), panes (C-w h/j/k/l), ret to open, go to each page, undo, the jumplist and the picker.
/// Owned by the shell — page areas register their own in their folder.
@MainActor
enum ShellCommands {
    static let motion: [KeyMode] = [.normal, .select]

    static func install(_ app: AppModel) {
        let r = app.registry

        // ── modes and layers ──
        r.register(Command(id: "mode.command", title: "Type a command (the : line)", scope: .global, verb: .command, label: "command", quiet: true,
                           local: { [weak app] _, _ in app?.keys.setMode(.command) }))
        r.register(Command(id: "mode.select", title: "Select a range (v again to stop)", scope: .global, verb: .select, modes: motion, label: "select",
                           local: { [weak app] _, _ in
                               guard let app else { return }
                               if app.keys.mode == .select { app.keys.setMode(.normal) } else { app.anchorHere(); app.keys.setMode(.select) }
                           }))
        r.register(Command(id: "menu.open", title: "Open the command menu", scope: .global, verb: .menu, label: "menu", quiet: true,
                           local: { [weak app] _, _ in app?.menuOpen = true }))
        r.register(Command(id: "help.keys", title: "Show every key", scope: .global, verb: .keys, modes: [.normal, .sheet], label: "keys",
                           local: { [weak app] _, _ in app?.sheetOpen.toggle() }))
        r.register(Command(
            id: "overlay.close", title: "Back out", scope: .global, verb: .cancel, label: "back", quiet: true,
            available: { [weak app] _ in app?.closers.contains { $0.isOpen() } ?? false },
            local: { [weak app] _, _ in app?.closers.first { $0.isOpen() }?.close() }))

        // ── the `:` line: printable keys go to its field; these are its own ──
        r.register(Command(id: "cmdline.next", title: "Next completion", scope: .global, verb: .next, modes: [.command], quiet: true,
                           local: { [weak app] _, _ in
                               guard let app else { return }
                               app.cmdIndex = min(max(0, app.completions.count - 1), app.cmdIndex + 1)
                           }))
        r.register(Command(id: "cmdline.prev", title: "Previous completion", scope: .global, verb: .previous, modes: [.command], quiet: true,
                           local: { [weak app] _, _ in app.map { $0.cmdIndex = max(0, $0.cmdIndex - 1) } }))
        r.register(Command(id: "cmdline.run", title: "Run the command", scope: .global, verb: .send, modes: [.command], quiet: true,
                           local: { [weak app] _, _ in app?.runCmdline() }))

        // ── motion through the focused pane ──
        r.register(Command(id: "cursor.down", title: "Next row", scope: .global, verb: .next, modes: motion, label: "row", pair: "cursor.up", quiet: true,
                           local: { [weak app] _, _ in app?.moveCursor(1) }))
        r.register(Command(id: "cursor.up", title: "Previous row", scope: .global, verb: .previous, modes: motion, label: "row", quiet: true,
                           local: { [weak app] _, _ in app?.moveCursor(-1) }))
        r.register(Command(id: "cursor.top", title: "First row", scope: .global, verb: .first, modes: motion, quiet: true,
                           local: { [weak app] _, _ in app?.cursorTo(0) }))
        r.register(Command(id: "cursor.bottom", title: "Last row", scope: .global, verb: .last, modes: motion, quiet: true,
                           local: { [weak app] _, _ in app?.cursorTo(Int.max) }))
        r.register(Command(id: "cursor.halfdown", title: "Down half a page", scope: .global, verb: .halfDown, modes: motion, quiet: true,
                           local: { [weak app] _, _ in app.map { $0.moveCursor(max(1, ($0.pane?.pageSize ?? 10))) } }))
        r.register(Command(id: "cursor.halfup", title: "Up half a page", scope: .global, verb: .halfUp, modes: motion, quiet: true,
                           local: { [weak app] _, _ in app.map { $0.moveCursor(-max(1, ($0.pane?.pageSize ?? 10))) } }))
        r.register(Command(id: "cursor.set", title: "Select row", scope: .global, needsArg: true, quiet: true,
                           local: { [weak app] key, _ in app?.setCursor(key) }))
        r.register(Command(id: "pane.open", title: "Open the row under the cursor", scope: .global, verb: .main, label: "open",
                           route: { [weak app] row in
                               guard let app, let row = row ?? app.selected else { return nil }
                               return app.provider?.primary(for: row, app)
                           }))
        r.register(Command(id: "pane.focus", title: "Focus a pane", scope: .global, needsArg: true, quiet: true,
                           local: { [weak app] id, _ in id.map { app?.focus(pane: $0) } }))
        for (d, verb) in [(Direction.left, Verb.paneLeft), (.down, .paneDown), (.up, .paneUp), (.right, .paneRight)] {
            r.register(Command(id: "pane.\(d.rawValue)", title: "Focus the pane \(d == .left || d == .right ? "to the \(d.rawValue)" : d == .up ? "above" : "below")",
                               scope: .global, verbs: [verb] + (d == .left ? [.left] : d == .right ? [.right] : []), quiet: true,
                               local: { [weak app] _, _ in if app?.focus(d) != true { throw Refusal("no pane \(d.rawValue)") } }))
        }
        r.register(Command(id: "pane.next", title: "Focus the next pane", scope: .global, verb: .paneNext, quiet: true,
                           local: { [weak app] _, _ in
                               guard let app, let here = app.pane else { return }
                               let ps = app.panes
                               let i = ps.firstIndex { $0.id == here.id } ?? 0
                               app.focus(pane: ps[(i + 1) % ps.count].id)
                           }))

        // ── pages ── (`g d` is Helix's go-to-definition on the review page, so the dashboard is `g s`)
        let go: [String: Verb] = ["forests": .goForests, "dashboard": .goDashboard, "todo": .goTodo, "machine": .goMachine, "wiki": .goWiki, "tutor": .goTutor]
        for s in Surface.all where !s.arg || s.bare {
            r.register(Command(id: "nav.\(s.id)", title: "Go to \(s.title)", scope: .global, verb: go[s.id],
                               local: { [weak app] _, _ in app?.go(Route(s.path)) }))
        }
        // the window's history: ⌘[ / ⌘] in the menu bar, and `:route.back` / `:route.forward`
        r.register(Command(id: "route.back", title: "Go back a page", scope: .global, quiet: true,
                           available: { [weak app] _ in !(app?.router.back.isEmpty ?? true) },
                           local: { [weak app] _, _ in app?.router.goBack() }))
        r.register(Command(id: "route.forward", title: "Go forward a page", scope: .global, quiet: true,
                           available: { [weak app] _ in !(app?.router.forward.isEmpty ?? true) },
                           local: { [weak app] _, _ in app?.router.goForward() }))

        // what the space menu finds by name: the arg is the branch or forest id ("<repo>:<name>")
        r.register(Command(id: "find.branch", title: "Open a branch you found", scope: .global, needsArg: true, quiet: true,
                           local: { [weak app] _, arg in
                               guard let id = arg as? String, let cut = id.firstIndex(of: ":") else { throw Refusal("no branch") }
                               app?.go(.review(repo: String(id[..<cut]), branch: String(id[id.index(after: cut)...])))
                           }))
        r.register(Command(id: "find.forest", title: "Open a forest you found", scope: .global, needsArg: true, quiet: true,
                           local: { [weak app] _, arg in
                               guard let app, let id = arg as? String, let p = app.store.view(Project.self, id) else { throw Refusal("that forest is gone") }
                               app.go(.forest(repo: p.repo, project: p.name))
                           }))

        // the server's asset signature moves with keys.toml, not keys-native.toml: this re-reads both
        r.register(Command(id: "keys.reload", title: "Re-read your keys (keys-native.toml, keys.toml)", scope: .global, quiet: true,
                           local: { [weak app] _, _ in
                               guard let app else { return }
                               Task { @MainActor in
                                   await app.loadBootstrap()
                                   app.runner.say(app.registry.keyProblems.isEmpty ? "keys re-read" : "keys re-read · \(app.registry.keyProblems.count) problems atop ?")
                               }
                           }))
        r.register(Command(id: "undo", title: "Undo the last change", scope: .global, verb: .undo, label: "undo",
                           local: { [weak app] _, _ in if app?.runner.undoLast() != true { throw Refusal("nothing to undo") } }))

        // ── the jumplist and the picker layer (commands/nav.ts) ──
        r.register(Command(id: "nav.back", title: "Jump back to where you were (the jumplist)", scope: .global, verb: .jumpBack, label: "back",
                           available: { [weak app] _ in !(app?.jumps.back.isEmpty ?? true) },
                           local: { [weak app] _, _ in if app?.jumpBack() != true { throw Refusal("nothing further back") } }))
        r.register(Command(id: "nav.forward", title: "Jump forward again (the jumplist)", scope: .global, verb: .jumpForward, label: "forward",
                           available: { [weak app] _ in !(app?.jumps.fwd.isEmpty ?? true) },
                           local: { [weak app] _, _ in if app?.jumpForward() != true { throw Refusal("nothing further forward") } }))
        let picking: (String?) -> Bool = { [weak app] _ in app?.nav.picker != nil }
        r.register(Command(id: "picker.down", title: "Next place in the picker", scope: .global, verb: .next, modes: [.picker], quiet: true,
                           available: picking, local: { [weak app] _, _ in app?.nav.move(1) }))
        r.register(Command(id: "picker.up", title: "Previous place in the picker", scope: .global, verb: .previous, modes: [.picker], quiet: true,
                           available: picking, local: { [weak app] _, _ in app?.nav.move(-1) }))
        r.register(Command(id: "picker.open", title: "Open the picked place", scope: .global, verb: .send, modes: [.picker], quiet: true,
                           available: picking, local: { [weak app] i, _ in app?.nav.choose(i.flatMap(Int.init)) }))
        r.register(Command(id: "picker.close", title: "Close the picker", scope: .global, quiet: true, available: picking,
                           local: { [weak app] _, _ in app?.nav.close() }))
    }
}
