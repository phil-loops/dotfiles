import AppKit
import CanopyCore
import SwiftUI

/// The branch's rendered evidence (GET /evidence, scripts/evidence_core.py): what the branch was
/// predicted to do to each scene, what the before/after renders show, and Phil's verdict on the exact
/// manifest on screen. Departures from the prediction come first; the machine never accepts anything.
public struct EvidenceCard: Decodable, Equatable, Sendable {
    public struct Request: Decodable, Equatable, Sendable { var recipe: String; var expectation: String }
    public struct Basis: Decodable, Equatable, Sendable { var beforeCommit: String; var afterCommit: String }
    public struct Recipe: Decodable, Equatable, Sendable { var title: String }
    public struct Obligation: Decodable, Equatable, Sendable { var id: String; var title: String? }
    public struct Side: Decodable, Equatable, Sendable { var scenes: [String: String] }
    public struct Measure: Decodable, Equatable, Sendable { var changedPixels: Int?; var maxDelta: Int? }
    public struct Finding: Decodable, Equatable, Sendable {
        var scene: String; var predicted: String; var changed: Bool; var departure: Bool; var measure: Measure?
        /// for a "field" prediction that changed: whether every changed pixel sits on the field itself
        var contained: Bool?

        var predictedWords: String {
            switch predicted {
            case "same": "unchanged"
            case "field": "only the field changes"
            default: "a change"
            }
        }
        var observedWords: String {
            guard changed else { return "unchanged" }
            switch contained {
            case true?: return "changed, only the field"
            case false?: return "changed beyond the field"
            case nil: return "changed"
            }
        }
    }
    public struct Manifest: Decodable, Equatable, Sendable {
        var basis: Basis; var recipe: Recipe; var expectation: String; var obligations: [Obligation]
        var before: Side; var after: Side; var findings: [Finding]
    }
    public struct Status: Decodable, Equatable, Sendable {
        var judged: Bool; var verdict: String?; var at: String?; var note: String?; var carriedFrom: String?
    }
    public struct Run: Decodable, Equatable, Sendable { var running: Bool; var exit: Int?; var tail: [String]? }

    var ok: Bool?
    var err: String?
    var error: String?
    var request: Request?
    var manifest: Manifest?
    var id: String?
    var current: Bool?
    var available: Bool?
    var status: Status?
    var run: Run?

    /// Scenes in reading order: what departed from the prediction first, then the recipe's order.
    var findings: [Finding] {
        guard let m = manifest else { return [] }
        let order = Dictionary(uniqueKeysWithValues: m.obligations.enumerated().map { ($1.id, $0) })
        return m.findings.sorted { ($0.departure ? 0 : 1, order[$0.scene] ?? 0) < ($1.departure ? 0 : 1, order[$1.scene] ?? 0) }
    }

    /// Phil may judge only a complete manifest of the branch as it is now.
    var judgeable: Bool { id != nil && current == true && available == true && run?.running != true }
}

let evidencePane = "evidence"

@MainActor @Observable
final class EvidenceState {
    var cards: [String: EvidenceCard] = [:]
    var images: [String: NSImage] = [:]
    /// nil: before and after side by side; else the one side shown alone, so a flip compares in place
    var alone: String?
    var generation = 0

    static func of(_ app: AppModel) -> EvidenceState { app.state { EvidenceState() } }

    func card(_ id: String) -> EvidenceCard? { cards[id] }

    static func rows(_ app: AppModel) -> [String] {
        guard let t = ReviewPageState.of(app).target, let c = of(app).cards[t.id] else { return [] }
        return c.findings.map { "e|\($0.scene)" }
    }

    func load(_ app: AppModel, _ t: ReviewPageState.Target) async {
        let path = app.transport.atRepo(t.repo, "/evidence?branch=\(t.name.uriComponent)")
        guard let c = try? await app.transport.getJSON(path, as: EvidenceCard.self) else { return }
        cards[t.id] = c
        for side in [c.manifest?.before, c.manifest?.after].compactMap({ $0 }) {
            for sha in side.scenes.values where images[sha] == nil {
                if let d = try? await app.transport.getData(app.transport.atRepo(t.repo, "/evidence-blob?sha=\(sha)")),
                   let img = NSImage(data: d) {
                    images[sha] = img
                }
            }
        }
    }
}

@MainActor
enum EvidenceCommands {
    static func install(_ app: AppModel) {
        let r = app.registry
        let pg = ReviewPageState.of(app)
        let ev = EvidenceState.of(app)
        let t = app.transport
        r.addScopes([.evidence], to: "review")
        r.register(Command(id: "evidence.open", title: "Show the evidence tab — before and after renders against the prediction",
                           scope: .review, leader: LocalKey(",e"), label: "evidence",
                           local: { _, _ in
                               pg.tab = pg.tab == "evidence" ? "files" : "evidence"
                               if pg.tab == "evidence" { app.focus(pane: evidencePane) }
                           }))
        r.register(Command(id: "evidence.flip", title: "Show before and after side by side, or flip one in place",
                           scope: .evidence, leader: LocalKey(",t"), label: "flip",
                           local: { _, _ in ev.alone = ev.alone == nil ? "before" : ev.alone == "before" ? "after" : nil }))
        func judged(_ verdict: String) -> (String, Any?) throws -> Write? {
            { _, _ in
                guard let tg = pg.target, let c = ev.card(tg.id), c.judgeable, let mid = c.id else { return nil }
                return Write(path: t.atRepo(tg.repo, "/evidence-judge"),
                             body: ["manifest": .string(mid), "verdict": .string(verdict)],
                             settled: { true },
                             said: verdict == "accept" ? "accepted what's on screen" : "rejected what's on screen",
                             failed: "the verdict didn't take",
                             answered: { _, _ in Task { @MainActor in await ev.load(app, tg); ev.generation += 1 } },
                             alone: true)
            }
        }
        let canJudge: (String?) -> Bool = { _ in pg.target.flatMap { ev.card($0.id) }?.judgeable ?? false }
        r.register(Command(id: "evidence.accept", title: "Accept this evidence — it looks the way you expected",
                           scope: .evidence, leader: LocalKey(",y"), label: "accept", quiet: true,
                           available: canJudge, write: judged("accept")))
        r.register(Command(id: "evidence.reject", title: "Reject this evidence — it doesn't look the way you expected",
                           scope: .evidence, leader: LocalKey(",N"), label: "reject", quiet: true,
                           available: canJudge, write: judged("reject")))
        r.register(Command(id: "evidence.run", title: "Render this branch's evidence again for its current code",
                           scope: .evidence, leader: LocalKey(",R"), label: "render", quiet: true,
                           write: { _, _ in
                               guard let tg = pg.target else { return nil }
                               return Write(path: t.atRepo(tg.repo, "/evidence-run"), body: ["branch": .string(tg.name)],
                                            settled: { true }, said: "rendering — the tab fills in when it's done",
                                            failed: "the render didn't start",
                                            answered: { _, _ in Task { @MainActor in await ev.load(app, tg); ev.generation += 1 } },
                                            alone: true)
                           }))
        r.place(.show, ["evidence.open", "evidence.flip", "evidence.accept", "evidence.reject", "evidence.run"])
    }
}

public extension Scope {
    /// the evidence tab is showing: flip, accept, reject, render
    static let evidence: Scope = "evidence"
}

struct EvidencePanel: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    let target: ReviewPageState.Target

    var body: some View {
        let ev = EvidenceState.of(app)
        let c = ev.card(target.id)
        VStack(alignment: .leading, spacing: 10) {
            if let c {
                header(c)
                if let m = c.manifest {
                    HStack(alignment: .top, spacing: 16) {
                        PaneList(pane: evidencePane, rows: EvidenceState.rows(app)) { key, on in
                            if let f = c.findings.first(where: { "e|\($0.scene)" == key }) { row(f, m, on: on) }
                        }
                        .frame(width: 380)
                        shots(m, ev)
                    }
                }
            } else {
                Text("reading evidence…").foregroundStyle(theme.inkFaint)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: "\(target.id)|\(app.store.view(Branch.self, target.id)?.tip ?? "")|\(ev.generation)") {
            await ev.load(app, target)
            while !Task.isCancelled, ev.card(target.id)?.run?.running == true {
                try? await Task.sleep(for: .seconds(2))
                await ev.load(app, target)
            }
        }
    }

    @ViewBuilder private func header(_ c: EvidenceCard) -> some View {
        if c.request == nil {
            Text(c.error ?? c.err ?? "No evidence request for this branch — one lives at ~/.dotfiles/evidence/requests/\(target.repo)/\(target.name).json")
                .foregroundStyle(theme.inkDim)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(c.manifest?.recipe.title ?? c.request?.recipe ?? "").font(Theme.display())
                    Spacer()
                    verdict(c)
                }
                Text(c.manifest?.expectation ?? c.request?.expectation ?? "")
                    .font(Theme.text(13)).foregroundStyle(theme.inkDim)
                    .padding(.leading, 10)
                    .overlay(alignment: .leading) { theme.goldDeep.frame(width: 2) }
                if let m = c.manifest {
                    Text("before \(m.basis.beforeCommit.prefix(10)) → after \(m.basis.afterCommit.prefix(10))")
                        .font(Theme.mono(11)).foregroundStyle(theme.inkFaint)
                }
                if let run = c.run, run.running {
                    Text("rendering… \(run.tail?.last ?? "")").font(Theme.mono(11)).foregroundStyle(theme.goldDeep)
                } else if let run = c.run, let code = run.exit, code != 0 {
                    Text("the last render failed: \(run.tail?.last ?? "exit \(code)")").font(Theme.mono(11)).foregroundStyle(theme.ember)
                } else if c.manifest == nil {
                    Text("nothing rendered yet").foregroundStyle(theme.inkFaint)
                } else if c.current != true {
                    Text("rendered for an older version of this branch").foregroundStyle(theme.ember)
                } else if c.available == false {
                    Text("these images are gone from the cache — render again").foregroundStyle(theme.ember)
                }
            }
        }
    }

    @ViewBuilder private func verdict(_ c: EvidenceCard) -> some View {
        if let s = c.status, s.judged {
            let word = s.verdict == "accept" ? "accepted" : "rejected"
            Text(s.carriedFrom != nil ? "\(word) · identical to what you judged \(s.at?.prefix(10) ?? "")" : "\(word) \(s.at?.prefix(10) ?? "")")
                .font(Theme.text(12)).foregroundStyle(s.verdict == "accept" ? theme.patina : theme.ember)
        } else if c.manifest != nil {
            Text("not judged").font(Theme.text(12)).foregroundStyle(theme.inkFaint)
        }
    }

    private func row(_ f: EvidenceCard.Finding, _ m: EvidenceCard.Manifest, on: Bool) -> some View {
        let title = m.obligations.first { $0.id == f.scene }?.title ?? f.scene
        let size = f.measure.flatMap { x in x.changedPixels.map { "\($0.formatted()) px, Δ\(x.maxDelta ?? 0)" } } ?? ""
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(f.departure ? "!" : " ").font(Theme.mono(12)).foregroundStyle(theme.ember)
                Text(title).font(Theme.text(13, weight: on ? .semibold : .regular))
            }
            Text("predicted \(f.predictedWords) · \(f.observedWords)\(size.isEmpty ? "" : " · \(size)")").lineLimit(1)
                .font(Theme.mono(11)).foregroundStyle(f.departure ? theme.ember : theme.inkFaint)
                .padding(.leading, 18)
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder private func shots(_ m: EvidenceCard.Manifest, _ ev: EvidenceState) -> some View {
        let scene = app.selected.flatMap { $0.hasPrefix("e|") ? String($0.dropFirst(2)) : nil } ?? EvidenceState.rows(app).first.map { String($0.dropFirst(2)) }
        if let scene {
            HStack(alignment: .top, spacing: 14) {
                ForEach(ev.alone.map { [$0] } ?? ["before", "after"], id: \.self) { side in
                    let sha = (side == "before" ? m.before : m.after).scenes[scene]
                    VStack(alignment: .leading, spacing: 4) {
                        Text(side).font(Theme.mono(11)).foregroundStyle(theme.inkFaint)
                        if let sha, let img = ev.images[sha] {
                            Image(nsImage: img).resizable().interpolation(.high)
                                .frame(width: img.size.width / 2, height: img.size.height / 2)
                        } else {
                            Text("…").foregroundStyle(theme.inkFaint)
                        }
                    }
                }
            }
        }
    }
}
