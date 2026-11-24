import AppKit
import CanopyCore
import Foundation
import Observation

/// Which branch each tmux pane is working on, whatever runs in it: `pane-branch`'s answer, read from the record the
/// reference-transaction hook writes in the pane that moved a branch. `⌃a n` opens pane n's branch, a forest's line
/// says where its panes sit, and each pane's border names its branch (the pane option `@pane_branch`).
@MainActor @Observable
final class PaneBranches {
    struct Row: Decodable, Equatable {
        var pane: String
        /// window:pane, with the session when it isn't the one tmux shows
        var address: String
        var repo: String?
        var branch: String?
    }

    static func of(_ app: AppModel) -> PaneBranches { app.state { PaneBranches() } }

    nonisolated static var script: String {
        ProcessInfo.processInfo.environment["CANOPY_PANE_BRANCH"] ?? ("~/.dotfiles/scripts/pane-branch" as NSString).expandingTildeInPath
    }
    nonisolated static var record: String {
        ProcessInfo.processInfo.environment["PANE_BRANCH_DIR"] ?? ("~/.cache/pane-branch" as NSString).expandingTildeInPath
    }

    /// what asking runs: `pane-branch` with these arguments, giving what it printed or what it said went wrong; tests swap it
    @ObservationIgnored var ask: @Sendable ([String]) -> Result<String, Refusal> = { args in
        let process = Zsh.process("exec \"$0\" \"$@\"", [PaneBranches.script] + args)
        let out = Pipe(), errors = Pipe()
        process.standardOutput = out
        process.standardError = errors
        do { try process.run() } catch { return .failure(Refusal(error.localizedDescription)) }
        let said = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let failed = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let why = failed.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(Refusal(why.hasPrefix("pane-branch: ") ? String(why.dropFirst(13)) : why.isEmpty ? "pane-branch failed" : why))
        }
        return .success(said)
    }
    /// what a border write runs; tests swap it
    @ObservationIgnored var tmux: ([String]) -> Void = { args in
        let p = Zsh.process("exec tmux \"$@\"", ["tmux"] + args)
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }

    /// what brings the terminal app forward, at once and before any pane is asked for; tests swap it
    @ObservationIgnored var raise: (pid_t) -> Void = { NSRunningApplication(processIdentifier: $0)?.activate() }
    /// the app the tmux client runs in (Terminal, Ghostty, …), as `pane-branch host` last said; nil until it has
    @ObservationIgnored var host: pid_t?

    private(set) var rows: [Row] = []
    @ObservationIgnored private(set) var written: [String: String] = [:]
    @ObservationIgnored private var task: Task<Void, Never>?

    /// The pid in `pane-branch host`'s answer: "<pid>\t<app>".
    nonisolated static func host(_ said: String) -> pid_t? { said.components(separatedBy: "\t").first.flatMap { pid_t($0) } }

    /// The page for what one pane's answer said: "<repo>\t<branch>".
    nonisolated static func route(_ said: String) -> Route? {
        let parts = said.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\t")
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return .review(repo: parts[0], branch: parts[1])
    }

    /// Where the panes on these branches sit, in tmux's order: a chat's pane, and any pane whose latest work is here.
    static func addresses(on branches: [BranchView], rows: [Row]) -> [String] {
        let chats = Set(branches.flatMap { $0.chats.compactMap(\.pane) })
        let here = Set(branches.map { "\($0.b.repo)\t\($0.b.name)" })
        return rows.filter { r in chats.contains(r.pane) || r.branch.map { here.contains("\(r.repo ?? "")\t\($0)") } == true }.map(\.address)
    }

    /// Opens the branch pane `n` of the shown tmux window is working on, asked now; a pane with none says why.
    @discardableResult
    func open(_ n: Int, _ app: AppModel) -> Task<Void, Never> { go([String(n)], app) }

    /// Ctrl-Space in tmux has already brought canopy forward: now go to the branch the pane it was pressed in is
    /// working on, and have that pane remembered for the way back. A pane with none says why and stays here.
    @discardableResult
    func follow(pane: String, _ app: AppModel) -> Task<Void, Never> {
        entered = (pane, Self.front(app))
        let going = go(["from", pane], app)
        return Task { [weak app] in
            await going.value
            if let app { self.entered = (pane, Self.front(app)) }
        }
    }

    /// the pane canopy was last entered from, and what was in front once it had gone to that pane's branch
    @ObservationIgnored private(set) var entered: (pane: String, front: String)?

    /// What is in front, as one word to compare: the page's branch, else the row under the cursor.
    static func front(_ app: AppModel) -> String {
        if case .review(let repo, let branch, _) = app.router.route { return "\(repo)\t\(branch)" }
        return app.selected ?? ""
    }

    private func go(_ args: [String], _ app: AppModel) -> Task<Void, Never> {
        let ask = ask
        return Task { [weak app] in
            let got = await Task.detached { ask(args) }.value
            guard let app else { return }
            switch got {
            case .success(let said):
                if let route = Self.route(said) { app.go(route) } else { app.runner.say("pane-branch said \(said.isEmpty ? "nothing" : said)") }
            case .failure(let why): app.runner.say(why.message)
            }
        }
    }

    /// What the way to tmux asks for: the panes of the chats on what's in front (the page's branch, else the branch or
    /// forest under the cursor), then that branch by name so a pane that committed there is found.
    static func wayBack(_ app: AppModel) -> [String] {
        let m = app.forestModel
        var named: (repo: String, branch: String)?, views: [BranchView] = []
        if case .review(let repo, let branch, _) = app.router.route {
            named = (repo, branch)
            views = m.forests().values.flatMap(\.branches).filter { $0.b.repo == repo && $0.b.name == branch }
        } else if let v = m.branchView(RowKey.id(app.selected, "b")) {
            named = (v.b.repo, v.b.name)
            views = [v]
        } else if let f = RowKey.id(app.selected, "p").flatMap({ m.forests()[$0] }) {
            views = f.branches
        }
        let prefer = WorkContext.onForest(views).compactMap(\.pane).flatMap { ["--prefer", $0] }
        return ["tmux"] + prefer + (named.map { [$0.repo, $0.branch] } ?? [])
    }

    /// Brings the terminal app forward at once (before it is known, `pane-branch` brings it forward itself), then has tmux go to the pane for what's in front — or, when canopy still
    /// shows what it showed on the way in, back to the pane it was entered from.
    @discardableResult
    func toTmux(_ app: AppModel) -> Task<Void, Never> {
        let host = host
        if let host { raise(host) }
        let unmoved = entered.flatMap { $0.front == Self.front(app) ? ["tmux", "--prefer", $0.pane] : nil }
        let ask = ask, args = (unmoved ?? Self.wayBack(app)) + (host == nil ? [] : ["--stay"])
        return Task { [weak app] in
            if case .failure(let why) = await Task.detached(operation: { ask(args) }).value { app?.runner.say(why.message) }
        }
    }

    /// Takes every pane's answer, and brings the borders to it, touching only the panes whose branch changed.
    func take(_ rows: [Row]) {
        if rows != self.rows { self.rows = rows }
        var want: [String: String] = [:]
        for r in rows { if let b = r.branch { want[r.pane] = leaf(b) } }
        for (pane, name) in want where written[pane] != name { tmux(["set-option", "-p", "-t", pane, "@pane_branch", name]) }
        for pane in written.keys where want[pane] == nil { tmux(["set-option", "-pu", "-t", pane, "@pane_branch"]) }
        written = want
    }

    /// When the record last changed: asking again is only worth it then, or once panes may have moved.
    nonisolated static func stamp() -> Date? {
        let dir = URL(fileURLWithPath: record)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }.max()
    }

    func start() {
        guard task == nil else { return }
        task = Task { @MainActor [weak self] in
            var seen: Date?, asked = Date.distantPast
            while !Task.isCancelled, let self {
                let stamp = Self.stamp()
                if stamp != seen || Date().timeIntervalSince(asked) > 30 {
                    seen = stamp
                    asked = Date()
                    let ask = self.ask
                    if case .success(let said) = await Task.detached(operation: { ask(["--json"]) }).value,
                       let rows = try? JSONDecoder().decode([Row].self, from: Data(said.utf8)) {
                        self.take(rows)
                    }
                    if case .success(let said) = await Task.detached(operation: { ask(["host"]) }).value {
                        self.host = Self.host(said)
                    }
                }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    static func install(_ app: AppModel) {
        app.registry.register(Command(id: "tmux.switch", title: "Go to the tmux pane working on this branch", scope: .global,
                                      verb: .tmuxSwitch, label: "tmux",
                                      local: { [weak app] _, _ in
                                          guard let app else { return }
                                          PaneBranches.of(app).toTmux(app)
                                      }))
        for n in 1...9 {
            app.registry.register(Command(id: "tmux.pane.\(n)", title: "Open the branch tmux pane \(n) is working on", scope: .global,
                                          verb: .tmux(n), label: "pane \(n)", recordsJump: true,
                                          local: { [weak app] _, _ in
                                              guard let app else { return }
                                              PaneBranches.of(app).open(n, app)
                                          }))
        }
    }
}
