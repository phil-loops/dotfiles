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

    private(set) var rows: [Row] = []
    @ObservationIgnored private(set) var written: [String: String] = [:]
    @ObservationIgnored private var task: Task<Void, Never>?

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
    func open(_ n: Int, _ app: AppModel) -> Task<Void, Never> {
        let ask = ask
        return Task { [weak app] in
            let got = await Task.detached { ask([String(n)]) }.value
            guard let app else { return }
            switch got {
            case .success(let said):
                if let route = Self.route(said) { app.go(route) } else { app.runner.say("pane \(n): pane-branch said \(said.isEmpty ? "nothing" : said)") }
            case .failure(let why): app.runner.say(why.message)
            }
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
                }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    static func install(_ app: AppModel) {
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
