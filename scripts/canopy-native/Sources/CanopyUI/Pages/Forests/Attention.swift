import CanopyCore
import Foundation
import Observation
import SwiftUI

/// One thing on a forest a session pinned for Phil (`stack-attention`): a place, what's wanted there, one sentence.
struct AttentionItem: Decodable, Equatable, Sendable, Identifiable {
    struct Done: Decodable, Equatable, Sendable { var at: String; var by: String }
    var id: String
    var forest: String
    var branch: String
    var file: String?
    var line: Int?
    var ask: String
    var text: String
    /// the branch's tip when it was written
    var tip: String?
    var by: String?
    var at: String?
    var done: Done?

    /// Whether the branch has moved since it was written: still open, but about an older tip.
    func stale(tip now: String?) -> Bool { now != tip }

    /// Where it points, as Phil reads it: the branch's leaf, then file:line.
    var place: String {
        [leaf(branch), file.map { ($0 as NSString).lastPathComponent + (line.map { ":\($0)" } ?? "") }].compactMap { $0 }.joined(separator: " · ")
    }

    /// The canopy address that lands on that place.
    func address(repo: String) -> String {
        var a = "/v2/b/\(repo)/\(branch)"
        if let file, let f = file.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=?+"))) {
            a += "?file=\(f)" + (line.map { "&line=\($0)" } ?? "")
        }
        return a
    }
}

/// The repo's item store (`$GIT_COMMON_DIR/stack-attention.json`), read whole; sign-offs go through the script.
struct AttentionIO: Sendable {
    /// the shared git dir of the repo canopy serves, and that repo's name
    var gitDir: String
    var repo: String
    var repoPath: String
    /// what a sign-off runs: `stack-attention` with these arguments in this environment; tests swap it
    var run: @Sendable ([String], [String: String]) -> Result<Void, Refusal> = AttentionIO.script

    var store: String { (gitDir as NSString).appendingPathComponent("stack-attention.json") }

    private struct File: Decodable { var items: [AttentionItem] }

    /// Every open item, in the order written.
    func open() -> [AttentionItem] {
        guard let data = FileManager.default.contents(atPath: store), let f = try? JSONDecoder().decode(File.self, from: data) else { return [] }
        return f.items.filter { $0.done == nil }
    }

    /// Phil's sign-off: `done <id> --by phil`, which the script refuses inside an agent session — so it runs without
    /// the variables a session would have left in canopy's environment when one launched it.
    func signOff(_ id: String) -> Result<Void, Refusal> {
        run(["done", id, "--by", "phil"], Self.asPhil(ProcessInfo.processInfo.environment).merging(["STACK_ATTENTION_REPO": repoPath]) { $1 })
    }

    /// The environment with every agent session's marks removed.
    static func asPhil(_ env: [String: String]) -> [String: String] {
        env.filter { k, _ in k != "CLAUDE_CODE_SESSION_ID" && k != "CLAUDECODE" && !k.hasPrefix("CODEX_") }
    }

    static let script: @Sendable ([String], [String: String]) -> Result<Void, Refusal> = { args, env in
        let p = Zsh.process("exec \"$0\" \"$@\"", [("~/.dotfiles/scripts/stack-attention" as NSString).expandingTildeInPath] + args)
        p.environment = env
        let errors = Pipe()
        p.standardOutput = FileHandle.nullDevice
        p.standardError = errors
        do { try p.run() } catch { return .failure(Refusal(error.localizedDescription)) }
        let said = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let why = said.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(Refusal(why.hasPrefix("stack-attention: ") ? String(why.dropFirst(17)) : why.isEmpty ? "stack-attention failed" : why))
        }
        return .success(())
    }

    /// The store of the repo canopy was started on, when it can be found.
    static func local(_ app: AppModel) -> AttentionIO? {
        let path = NSString(string: app.config.repo ?? "~/coding/loops").expandingTildeInPath
        guard let dir = AppModel.gitCommonDir(path) else { return nil }
        return AttentionIO(gitDir: dir, repo: (path as NSString).lastPathComponent, repoPath: path)
    }
}

/// The open items of the repo canopy serves, read again whenever the store is written.
@MainActor @Observable
final class Attention {
    static func of(_ app: AppModel) -> Attention { app.state { Attention(io: AttentionIO.local(app)) } }

    @ObservationIgnored var io: AttentionIO?
    private(set) var items: [AttentionItem] = []
    @ObservationIgnored private var watch: RecordWatch?

    init(io: AttentionIO?) { self.io = io }

    /// A forest's open items, in the order written; nothing for a forest of a repo whose store canopy can't find.
    func on(repo: String, forest: String) -> [AttentionItem] {
        guard io?.repo == repo else { return [] }
        return items.filter { $0.forest == forest }
    }

    func item(_ id: String?) -> AttentionItem? { items.first { $0.id == id } }

    /// Reads the store now and again on every write to it.
    func start() async {
        guard let io else { return }
        if watch == nil {
            watch = RecordWatch(dir: io.gitDir, wanted: { $0 == "stack-attention.json" }) { [weak self] in
                Task { await self?.read() }
            }
        }
        await read()
    }

    func read() async {
        guard let io else { return }
        let got = await Task.detached { io.open() }.value
        if got != items { items = got }
    }

    /// Signs an item off as Phil; it leaves the list once the store says so.
    func signOff(_ id: String) async throws {
        guard let io else { throw Refusal("canopy can't find this repo's attention store") }
        if case .failure(let why) = await Task.detached(operation: { io.signOff(id) }).value { throw why }
        await read()
    }

    static let scope: Scope = "attention"

    /// The forest page's branch rows that need Phil's eyes (an open item pinned on them), in merge order.
    static func eyesRows(_ app: AppModel) -> [String] {
        let pinned = Set(ForestPage.attentionItems(app).map(\.branch))
        return app.forestModel.forestRows(app.forestModel.pageProject).filter { key in
            RowKey.id(key, "b").flatMap { app.store.view(Branch.self, $0) }.map { pinned.contains($0.name) } == true
        }
    }

    /// `]d` / `[d`: the cursor to the next or previous branch that needs Phil's eyes, from where it is in the branches
    /// (from anywhere else, the first or last); a jump, so `C-o` comes back.
    static func step(_ app: AppModel, _ delta: Int) throws {
        let eyes = eyesRows(app)
        guard !eyes.isEmpty else { throw Refusal("no branch on this forest needs your eyes") }
        let rows = app.forestModel.forestRows(app.forestModel.pageProject)
        let here = app.isFocused("main") ? app.selected.flatMap { rows.firstIndex(of: $0) } : nil
        let target: String?
        if let here {
            target = delta > 0 ? eyes.first { rows.firstIndex(of: $0)! > here } : eyes.last { rows.firstIndex(of: $0)! < here }
        } else {
            target = delta > 0 ? eyes.first : eyes.last
        }
        guard let target else { throw Refusal(delta > 0 ? "no branch below needs your eyes" : "no branch above needs your eyes") }
        app.jump {
            app.focus(pane: "main")
            app.setCursor(target)
        }
        let name = RowKey.id(target, "b").flatMap { app.store.view(Branch.self, $0)?.name }
        let first = ForestPage.attentionItems(app).first { $0.branch == name }
        app.runner.say("\((eyes.firstIndex(of: target) ?? 0) + 1) of \(eyes.count) that need your eyes" + (first.map { ": \($0.ask) — \($0.text)" } ?? ""))
    }

    static func install(_ app: AppModel) {
        let r = app.registry
        r.addScopes([scope], to: "forest")
        r.register(Command(id: "attention.open", title: "Go to the place the item points at", scope: scope, verb: .main, label: "open",
                           local: { [weak app] id, _ in
                               guard let app, let i = Attention.of(app).item(id), let io = Attention.of(app).io else { return }
                               app.open(address: i.address(repo: io.repo), source: "attention")
                           }))
        r.register(Command(id: "attention.next", title: "The next branch that needs your eyes", scope: .forest, verb: .nextFinding,
                           modes: [.normal, .select], quiet: true, local: { [weak app] _, _ in if let app { try step(app, 1) } }))
        r.register(Command(id: "attention.prev", title: "The previous branch that needs your eyes", scope: .forest, verb: .previousFinding,
                           modes: [.normal, .select], quiet: true, local: { [weak app] _, _ in if let app { try step(app, -1) } }))
        r.register(Command(id: "attention.done", title: "Sign the item off", scope: scope, verb: .putAway, label: "sign off",
                           local: { [weak app] id, _ in
                               guard let app, let id else { return }
                               Task {
                                   do { try await Attention.of(app).signOff(id) } catch let why as Refusal { app.runner.say(why.message) }
                               }
                           }))
    }
}

/// The forest's open items, above its branches: the place, what's wanted, the sentence; one about an older tip dimmed
/// and saying so. ↵ goes there, X signs it off.
struct AttentionList: View {
    @Environment(\.theme) private var theme
    let items: [AttentionItem]
    let tips: [String: String]

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                SectionHead(text: "for you").padding(.leading, 52).padding(.bottom, 4)
                ForEach(items) { i in
                    let stale = i.stale(tip: tips[i.branch])
                    CursorRow(pane: "attention", key: RowKey.attention(i.id)) { on in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text(i.ask).font(Theme.text(11.5)).foregroundStyle(stale ? theme.inkFaint : theme.ember).frame(width: 44, alignment: .leading)
                                Text(i.place).foregroundStyle(on ? theme.goldLeaf : theme.ink).lineLimit(1)
                                if stale { Text("moved since this was written").font(Theme.text(11)).foregroundStyle(theme.inkFaint) }
                            }
                            Text(i.text).font(Theme.text(12)).foregroundStyle(theme.inkDim).lineLimit(2).padding(.leading, 54)
                        }
                        .opacity(stale ? 0.6 : 1)
                        .frame(minHeight: 28)
                        .padding(.leading, 52).padding(.trailing, 20).padding(.vertical, 3)
                    }
                }
            }
            .cursorMarks("attention")
            .padding(.bottom, 16)
        }
    }
}
