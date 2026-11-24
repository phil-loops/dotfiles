import CanopyCore
import Foundation

/// Each bound chat's forest, in the home's words, on its tmux pane's border: the pane option `@chat_state`
/// (tmux.conf draws it after the chat's label). Written only when it changes, and cleared when the chat
/// leaves the forest.
@MainActor
final class PaneStates {
    static func of(_ app: AppModel) -> PaneStates { app.state { PaneStates() } }

    /// what a write runs; tests swap it
    var tmux: ([String]) -> Void = { args in
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Zsh.path)
        p.arguments = Zsh.arguments("exec tmux \"$@\"", ["tmux"] + args)
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }
    private(set) var written: [String: String] = [:]
    private var task: Task<Void, Never>?

    /// What each pane's border should say: the forest its chat is on, as "<verb> · <its one step>". A chat
    /// on several forests takes the one its label names, else the first by name.
    static func states(_ forests: [ForestView], verb: (ForestView) -> HomeVerb) -> [String: String] {
        var out: [String: String] = [:]
        for f in forests.sorted(by: { $0.p.name < $1.p.name }) where !f.closed {
            let words = [verb(f).title, f.says].filter { !$0.isEmpty }.joined(separator: " · ")
            for c in WorkContext.onForest(f.branches) {
                guard let pane = c.pane else { continue }
                if out[pane] == nil || c.label == f.p.name { out[pane] = words }
            }
        }
        return out
    }

    /// Brings the panes to `want`, touching only the ones whose words changed.
    func apply(_ want: [String: String]) {
        for (pane, words) in want where written[pane] != words { tmux(["set-option", "-p", "-t", pane, "@chat_state", words]) }
        for pane in written.keys where want[pane] == nil { tmux(["set-option", "-pu", "-t", pane, "@chat_state"]) }
        written = want
    }

    func start(_ app: AppModel) {
        guard task == nil else { return }
        PaneBranches.of(app).start()
        task = Task { @MainActor [weak app] in
            while !Task.isCancelled, let app {
                let m = app.forestModel
                apply(Self.states(Array(m.forests().values), verb: m.verb))
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }
}
