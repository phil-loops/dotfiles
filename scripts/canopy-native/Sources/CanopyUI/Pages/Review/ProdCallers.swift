import CanopyCore
import SwiftUI

/// Which production entry points reach what the branch changes, at its tip: the server's kept answer (POST /callers,
/// scripts/prod-callers). The branch page asks for it for the tip it shows; `review.callers` opens the call paths.
@MainActor @Observable
final class ProdCallers {
    struct Step: Decodable, Equatable { var path: String; var name: String }
    struct Reach: Decodable, Equatable { var by: String; var how: String; var behind: String?; var path: [Step] }
    struct Stop: Decodable, Equatable { var why: String; var at: [Step] }
    struct Declaration: Decodable, Equatable {
        var name: String
        var answer: String
        var reached: [Reach]
        var unresolved: [Stop]
        var under: String?
    }
    struct Found: Decodable, Equatable { var declarations: [Declaration]; var connects: [Declaration] }
    struct Answer: Decodable, Equatable { var ok: Bool; var state: String; var result: Found?; var message: String? }

    /// How much a line asks of the reader, loudest first: wired into production with no flag found or a path that
    /// couldn't be followed; wired in behind a flag; already live; reached by nothing.
    enum Tone: Int, Comparable {
        case loud, fresh, live, quiet
        static func < (a: Tone, b: Tone) -> Bool { a.rawValue < b.rawValue }
    }
    struct Line: Equatable { var text: String; var tone: Tone; var paths: [String] }

    static func of(_ app: AppModel) -> ProdCallers { app.state { ProdCallers() } }

    private(set) var answers: [String: Answer] = [:]
    var open: Set<String> = []
    /// what asking sends: (repo, branch, start it if it was never worked out); tests swap it
    @ObservationIgnored var ask: ((String, String, Bool) async -> Answer?)?
    @ObservationIgnored var pause: UInt64 = 3_000_000_000

    /// One line per changed declaration, loudest first. A helper that only matters through another changed
    /// declaration is that one's change and gets no line of its own.
    static func lines(_ found: Found) -> [Line] {
        func names(_ reached: [Reach]) -> String {
            let by = reached.map(\.by)
            return by.prefix(2).joined(separator: ", ") + (by.count > 2 ? " and others" : "")
        }
        let own = found.declarations.filter { $0.under == nil } + found.connects
        let lines = own.map { d -> Line in
            let paths = d.reached.map { $0.path.map(\.name).joined(separator: " ← ") }
                + d.unresolved.map { "stopped (\($0.why)) at " + $0.at.map(\.name).joined(separator: " ← ") }
            let fresh = d.reached.filter { $0.how == "connected" }
            switch d.answer {
            case "existing":
                return Line(text: "\(d.name) is reached by \(names(d.reached.filter { $0.how == "existing" }))", tone: .live, paths: paths)
            case "connected":
                let flags = Array(Set(fresh.compactMap(\.behind))).sorted()
                let bare = fresh.contains { $0.behind == nil }
                return Line(text: "\(d.name) newly reaches \(names(fresh)), " + (bare ? "no flag found" : "behind \(flags.joined(separator: ", "))"),
                            tone: bare ? .loud : .fresh, paths: paths)
            case "none":
                return Line(text: "\(d.name) has no production caller", tone: .quiet, paths: [])
            default:
                return Line(text: "\(d.name): call path unresolved", tone: .loud, paths: paths)
            }
        }
        return lines.enumerated().sorted { ($0.element.tone, $0.offset) < ($1.element.tone, $1.offset) }.map(\.element)
    }

    /// Reads the kept answer for the branch's tip, starting the walk when `run` and it was never worked out, and
    /// stays with it while the server is still working.
    func load(_ id: String, repo: String, branch: String, run: Bool, _ app: AppModel) async {
        var run = run
        while !Task.isCancelled {
            let got: Answer?
            if let ask { got = await ask(repo, branch, run) } else {
                got = await app.transport.ask(app.transport.atRepo(repo, "/callers"), ["branch": JSONValue.string(branch), "run": JSONValue.bool(run)])
            }
            answers[id] = got
            guard got?.state == "running" else { return }
            run = false
            try? await Task.sleep(nanoseconds: pause)
        }
    }

    static func install(_ app: AppModel) {
        app.registry.register(Command(
            id: "review.callers", title: "Show how production reaches this branch's changes", scope: .review, label: "prod callers",
            task: { [weak app] id, _ in
                guard let app, let id, let b = app.store.view(Branch.self, id) else { return nil }
                let callers = ProdCallers.of(app)
                if callers.answers[id]?.result != nil {
                    callers.open.formSymmetricDifference([id])
                    return nil
                }
                await callers.load(id, repo: b.repo, branch: b.name, run: true, app)
                return nil
            }))
    }
}

/// The branch page's line for it: the loudest finding, and every finding with its call paths once opened.
struct ProdCallersView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    let branch: Branch

    private func color(_ tone: ProdCallers.Tone) -> Color {
        switch tone {
        case .loud: theme.ember
        case .fresh: theme.goldLeaf
        case .live: theme.inkDim
        case .quiet: theme.inkFaint
        }
    }

    var body: some View {
        let callers = ProdCallers.of(app)
        let answer = callers.answers[branch.id]
        VStack(alignment: .leading, spacing: 2) {
            if answer?.state == "running" {
                Text("finding production callers…").foregroundStyle(theme.inkFaint)
            } else if answer?.state == "failed" {
                Text("production callers: \(answer?.message ?? "the walk failed")").foregroundStyle(theme.inkFaint).lineLimit(1)
            } else if let found = answer?.result {
                let lines = ProdCallers.lines(found)
                let open = callers.open.contains(branch.id)
                ForEach(Array((open ? lines : Array(lines.prefix(1))).enumerated()), id: \.offset) { n, line in
                    Button { app.runner.dispatch("review.callers", via: .click, target: branch.id) } label: {
                        Text(line.text + (!open && lines.count > 1 ? " · more" : "")).foregroundStyle(color(line.tone)).lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .labelTarget(pane: "prod-callers", key: "line.\(n)", title: "prod callers", run: RouteTo("review.callers", target: branch.id))
                    if open {
                        ForEach(line.paths, id: \.self) { Text($0).foregroundStyle(theme.inkFaint).lineLimit(1).truncationMode(.middle).padding(.leading, 12) }
                    }
                }
            }
        }
        .font(Theme.text(11))
        .task(id: branch.tip) { await callers.load(branch.id, repo: branch.repo, branch: branch.name, run: true, app) }
    }
}
