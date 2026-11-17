import AppKit
import CanopyCore
import SwiftUI

/// The branch's rendered evidence (GET /evidence, scripts/evidence_core.py), read as a proof sheet:
/// every field the branch changes as one tile split before | after, swept through its variants
/// (light, dark, focused) together; one field enlarged into a wipe with its changed pixels lit; the
/// measured facts in words; what wasn't captured, said. Phil judges the whole manifest on screen.
public struct EvidenceCard: Decodable, Equatable, Sendable {
    public struct Request: Decodable, Equatable, Sendable { var recipe: String; var expectation: String; var gaps: [String]? }
    public struct Basis: Decodable, Equatable, Sendable { var beforeCommit: String; var afterCommit: String }
    public struct Recipe: Decodable, Equatable, Sendable { var title: String }
    public struct Obligation: Decodable, Equatable, Sendable {
        var id: String; var title: String?
        var view: String?; var viewTitle: String?; var variant: String?; var variantTitle: String?
    }
    public struct Side: Decodable, Equatable, Sendable { var scenes: [String: String]; var fields: [String: [Int]]?; var capturedAt: String? }
    public struct Asked: Decodable, Equatable, Sendable { var expectation: String; var predict: [String: String] }
    /// the UI files the change touches, measured from the diff, and which of them a scene looks at
    public struct Coverage: Decodable, Equatable, Sendable { var changed: [String]; var covered: [String]; var uncovered: [String]; var unverified: [String]? }
    public struct Measure: Decodable, Equatable, Sendable {
        var changedPixels: Int?; var maxDelta: Int?; var box: [Int]?; var sizeChanged: [Int]?
    }
    public struct Finding: Decodable, Equatable, Sendable {
        var scene: String; var predicted: String; var changed: Bool; var departure: Bool; var measure: Measure?
        /// identical pixels, but the picture sat somewhere else on the page
        var moved: Bool?
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
            guard changed else { return moved == true ? "same pixels, moved on the page" : "unchanged" }
            switch contained {
            case true?: return "changed, only the field"
            case false?: return "changed beyond the field"
            case nil: return "changed"
            }
        }
    }
    public struct Manifest: Decodable, Equatable, Sendable {
        var basis: Basis; var recipe: Recipe; var expectation: String; var obligations: [Obligation]
        var before: Side; var after: Side; var findings: [Finding]; var gaps: [String]?
        /// "live" (local previews under a shared dev environment: repeatable, not reproducible) or "deterministic"
        var claim: String?
        /// what the captures were predicted under; a re-explanation keeps it
        var captured: Asked?
        var amends: String?; var retrospective: Bool?
        var coverage: Coverage?
    }
    public struct Status: Decodable, Equatable, Sendable {
        var judged: Bool; var verdict: String?; var at: String?; var note: String?; var carriedFrom: String?; var stands: Bool?
    }
    public struct Run: Decodable, Equatable, Sendable { var running: Bool; var exit: Int?; var tail: [String]? }

    /// One field the branch changes: its scenes by variant. A component recipe's scenes are each their own.
    public struct Field: Equatable, Sendable { var id: String; var title: String; var scenes: [String: String] }
    public struct Variant: Equatable, Sendable { var id: String; var title: String }

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
    /// the engine's one eligibility check: false, with reasons, when this can't be judged or carried
    var eligible: Bool?
    /// stale behind another evidence run on the machine — its re-capture starts when that one ends
    var waiting: Bool?
    var why: [String]?

    /// Scenes in reading order: what departed from the prediction first, then the recipe's order.
    var findings: [Finding] {
        guard let m = manifest else { return [] }
        let order = Dictionary(uniqueKeysWithValues: m.obligations.enumerated().map { ($1.id, $0) })
        return m.findings.sorted { ($0.departure ? 0 : 1, order[$0.scene] ?? 0) < ($1.departure ? 0 : 1, order[$1.scene] ?? 0) }
    }

    var fields: [Field] {
        var out: [Field] = []
        for o in manifest?.obligations ?? [] {
            let id = o.view ?? o.id
            if let i = out.firstIndex(where: { $0.id == id }) {
                out[i].scenes[o.variant ?? ""] = o.id
            } else {
                out.append(Field(id: id, title: o.viewTitle ?? o.title ?? o.id, scenes: [o.variant ?? "": o.id]))
            }
        }
        return out
    }

    var variants: [Variant] {
        var out: [Variant] = []
        for o in manifest?.obligations ?? [] where !out.contains(where: { $0.id == (o.variant ?? "") }) {
            out.append(Variant(id: o.variant ?? "", title: o.variantTitle ?? o.variant ?? ""))
        }
        return out
    }

    func finding(_ scene: String) -> Finding? { manifest?.findings.first { $0.scene == scene } }

    /// What the measurements say about one scene, in words: the field's own size change, and whether
    /// anything around it changed too. Never a verdict — Phil's eyes make that.
    func facts(_ scene: String) -> [String] {
        guard let m = manifest, let f = finding(scene) else { return [] }
        guard f.changed else { return [f.observedWords] }
        var out: [String] = []
        if let b = m.before.fields?[scene], let a = m.after.fields?[scene], b.count == 4, a.count == 4 {
            let dw = (a[2] - b[2]) / 2, dh = (a[3] - b[3]) / 2
            if dw != 0 { out.append("\(abs(dw))px \(dw > 0 ? "wider" : "narrower")") }
            if dh != 0 { out.append("\(abs(dh))px \(dh > 0 ? "taller" : "shorter")") }
            if dw == 0, dh == 0 { out.append("same size") }
        }
        if f.measure?.sizeChanged != nil { out.append("the picture changed size") }
        if f.departure { out.append(f.predicted == "field" ? "something around it changed too" : "predicted \(f.predictedWords)") }
        return out
    }

    /// Phil may judge only a complete manifest of the branch as it is now.
    var judgeable: Bool { id != nil && current == true && available == true && run?.running != true && eligible != false }
    /// Judgeable, and every image of the manifest is on screen — `available` only says the server has them.
    func judgeable(showing has: (String) -> Bool) -> Bool {
        judgeable && [manifest?.before, manifest?.after].allSatisfy { $0?.scenes.values.allSatisfy(has) ?? false }
    }

    /// The claim in words — what accepting this does and doesn't establish.
    var claimWords: String? {
        guard let m = manifest else { return nil }
        switch m.claim {
        case "live":
            let at = m.after.capturedAt.map { " · captured \($0.prefix(16).replacingOccurrences(of: "T", with: " "))" } ?? ""
            return "live capture: local previews of each commit against the shared dev database — repeatable, not reproducible\(at)"
        case "deterministic": return "deterministic render: each commit's own code, admitted by two independent renders"
        default: return nil
        }
    }
}

let evidencePane = "evidence"

@MainActor @Observable
final class EvidenceState {
    var cards: [String: EvidenceCard] = [:]
    var images: [String: NSImage] = [:]
    var heats: [String: NSImage] = [:]
    /// nil: every tile split before | after; else every tile showing that one side, so a flip
    /// moves the whole sheet at once and the fields that changed are the ones that jump
    var alone: String?
    /// the variant the sheet shows (light, dark, focused…); nil until a card arrives
    var variant: String?
    /// one field enlarged into a wipe
    var zoomed = false
    /// where the wipe's seam sits: before shows left of it, after right — 0 is all after, 1 all before
    var seam = 0.5
    /// the enlarged field's changed pixels lit
    var changes = false
    /// tiles per row, as laid out — j/k move a row
    var columns = 4
    var generation = 0

    static func of(_ app: AppModel) -> EvidenceState { app.state { EvidenceState() } }

    func card(_ id: String) -> EvidenceCard? { cards[id] }

    static func rows(_ app: AppModel) -> [String] {
        guard let t = ReviewPageState.of(app).target, let c = of(app).cards[t.id] else { return [] }
        return c.fields.map { "e|\($0.id)" }
    }

    /// The variant on screen: the chosen one, else dark (where theming bugs live), else the first.
    func variant(_ c: EvidenceCard) -> String {
        let vs = c.variants.map(\.id)
        if let v = variant, vs.contains(v) { return v }
        return vs.first { $0 == "dark" } ?? vs.first ?? ""
    }

    /// Whether `c` can be judged as it stands on screen now.
    func shown(_ c: EvidenceCard) -> Bool { c.judgeable(showing: { images[$0] != nil }) }

    func loadCard(_ app: AppModel, _ t: ReviewPageState.Target) async {
        let path = app.transport.atRepo(t.repo, "/evidence?branch=\(t.name.uriComponent)")
        guard let c = try? await app.transport.getJSON(path, as: EvidenceCard.self) else { return }
        cards[t.id] = c
    }

    func load(_ app: AppModel, _ t: ReviewPageState.Target) async {
        await loadCard(app, t)
        guard let c = cards[t.id] else { return }
        for side in [c.manifest?.before, c.manifest?.after].compactMap({ $0 }) {
            for sha in side.scenes.values where images[sha] == nil {
                if let d = try? await app.transport.getData(app.transport.atRepo(t.repo, "/evidence-blob?sha=\(sha)")),
                   let img = NSImage(data: d) {
                    images[sha] = img
                }
            }
        }
    }

    private var crops: [String: NSImage] = [:]

    /// A capture cut to `region` (device px, top-left origin), clamped to the picture; the whole
    /// capture when there's no region.
    func around(_ sha: String, _ region: CGRect?) -> NSImage? {
        guard let img = images[sha] else { return nil }
        guard let region else { return img }
        let key = "\(sha)|\(region.debugDescription)"
        if let c = crops[key] { return c }
        guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return img }
        let r = region.intersection(CGRect(x: 0, y: 0, width: cg.width, height: cg.height)).integral
        guard !r.isEmpty, let cut = cg.cropping(to: r) else { return img }
        let out = NSImage(cgImage: cut, size: NSSize(width: r.width, height: r.height))
        crops[key] = out
        return out
    }

    /// The after picture dimmed, with every pixel that differs from before lit in gold.
    func heat(_ before: String, _ after: String) -> NSImage? {
        let key = before + after
        if let h = heats[key] { return h }
        guard let b = images[before], let a = images[after], let h = Self.lit(b, a) else { return nil }
        heats[key] = h
        return h
    }

    nonisolated static func lit(_ before: NSImage, _ after: NSImage) -> NSImage? {
        guard let bc = before.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let ac = after.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let w = ac.width, h = ac.height
        func pixels(_ img: CGImage) -> [UInt8]? {
            guard img.width == w, img.height == h else { return nil }
            var buf = [UInt8](repeating: 0, count: w * h * 4)
            guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return nil }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return buf
        }
        guard var out = pixels(ac) else { return nil }
        let old = pixels(bc)
        for i in stride(from: 0, to: out.count, by: 4) {
            var d = old == nil ? 255 : 0
            if let old { for c in 0..<3 { d = max(d, abs(Int(old[i + c]) - Int(out[i + c]))) } }
            if d > 8 {
                out[i] = 230; out[i + 1] = 182; out[i + 2] = 78
            } else {
                let g = UInt8((Int(out[i]) + Int(out[i + 1]) + Int(out[i + 2])) / 3 * 35 / 100)
                out[i] = g; out[i + 1] = g; out[i + 2] = g
            }
            out[i + 3] = 255
        }
        let data = Data(out) as CFData
        guard let provider = CGDataProvider(data: data),
              let img = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        return NSImage(cgImage: img, size: after.size)
    }
}

@MainActor
enum EvidenceCommands {
    static func install(_ app: AppModel) {
        let r = app.registry
        let pg = ReviewPageState.of(app)
        let ev = EvidenceState.of(app)
        let t = app.transport
        let card = { pg.target.flatMap { ev.card($0.id) } }
        r.addScopes([.evidence], to: "review")
        r.register(Command(id: "evidence.open", title: "Show the evidence tab — every changed field, before and after",
                           scope: .review, leader: LocalKey(",e"), label: "evidence",
                           local: { _, _ in
                               pg.tab = pg.tab == "evidence" ? "files" : "evidence"
                               if pg.tab == "evidence" { app.focus(pane: evidencePane) }
                           }))
        r.register(Command(id: "evidence.down", title: "The field below", scope: .evidence, verb: .next, label: "field", pair: "evidence.up", quiet: true,
                           local: { _, _ in app.moveCursor(ev.columns) }))
        r.register(Command(id: "evidence.up", title: "The field above", scope: .evidence, verb: .previous, quiet: true,
                           local: { _, _ in app.moveCursor(-ev.columns) }))
        r.register(Command(id: "evidence.left", title: "The field before, or (enlarged) slide the seam left: more after",
                           scope: .evidence, verb: .left, label: "field / wipe", pair: "evidence.right", quiet: true,
                           local: { _, _ in if ev.zoomed { ev.seam = max(0, ev.seam - 0.1) } else { app.moveCursor(-1) } }))
        r.register(Command(id: "evidence.right", title: "The field after, or (enlarged) slide the seam right: more before",
                           scope: .evidence, verb: .right, quiet: true,
                           local: { _, _ in if ev.zoomed { ev.seam = min(1, ev.seam + 0.1) } else { app.moveCursor(1) } }))
        r.register(Command(id: "evidence.zoom", title: "Enlarge the field into a wipe (esc puts it back)", scope: .evidence, verb: .main, label: "enlarge",
                           local: { _, _ in ev.zoomed = true; ev.seam = 0.5 }))
        r.register(Command(id: "evidence.flip", title: "Flip every field at once: split, all before, all after",
                           scope: .evidence, leader: LocalKey(",t"), label: "flip",
                           local: { _, _ in ev.alone = ev.alone == nil ? "before" : ev.alone == "before" ? "after" : nil }))
        r.register(Command(id: "evidence.variant", title: "Show the next variant (light, dark, focused…) on every field",
                           scope: .evidence, leader: LocalKey(",v"), label: "variant",
                           local: { _, _ in
                               guard let c = card() else { return }
                               let vs = c.variants.map(\.id)
                               guard let i = vs.firstIndex(of: ev.variant(c)) else { return }
                               ev.variant = vs[(i + 1) % vs.count]
                           }))
        for n in 1...4 {
            r.register(Command(id: "evidence.variant.\(n)", title: "Show variant \(n) on every field", scope: .evidence, verb: .nth(n), quiet: true,
                               available: { _ in (card()?.variants.count ?? 0) >= n },
                               local: { _, _ in if let c = card(), c.variants.count >= n { ev.variant = c.variants[n - 1].id } }))
        }
        r.register(Command(id: "evidence.changes", title: "Light the pixels that changed on the enlarged field",
                           scope: .evidence, leader: LocalKey(",c"), label: "changes",
                           local: { _, _ in ev.changes.toggle(); if ev.changes { ev.zoomed = true } }))
        func judged(_ verdict: String) -> (String, Any?) throws -> Write? {
            { _, _ in
                guard let tg = pg.target, let c = ev.card(tg.id), ev.shown(c), let mid = c.id else { return nil }
                return Write(path: t.atRepo(tg.repo, "/evidence-judge"),
                             body: ["branch": .string(tg.name), "manifest": .string(mid), "verdict": .string(verdict)],
                             settled: { true },
                             said: verdict == "accept" ? "accepted every field as shown" : "rejected what's on screen",
                             failed: "the verdict didn't take",
                             answered: { _, _ in Task { @MainActor in await ev.load(app, tg); ev.generation += 1 } },
                             alone: true)
            }
        }
        let canJudge: (String?) -> Bool = { _ in card().map(ev.shown) ?? false }
        r.register(Command(id: "evidence.accept", title: "Accept this evidence — every field looks the way you expected",
                           scope: .evidence, leader: LocalKey(",y"), label: "accept", quiet: true,
                           available: canJudge, write: judged("accept")))
        r.register(Command(id: "evidence.reject", title: "Reject this evidence — something doesn't look the way you expected",
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
        r.place(.show, ["evidence.open", "evidence.flip", "evidence.variant", "evidence.changes", "evidence.accept", "evidence.reject", "evidence.run"])
    }
}

public extension Scope {
    /// the evidence tab is showing: move between fields, flip, sweep variants, enlarge, judge
    static let evidence: Scope = "evidence"
}

/// The branch page's pointer to its evidence, beside the ship strip: what it covers and whether
/// Phil has judged it, with the key that opens it.
struct EvidenceChip: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    let target: ReviewPageState.Target

    var body: some View {
        let ev = EvidenceState.of(app)
        // a zero-size anchor: SwiftUI never runs the .task of a view that draws nothing, and the chip
        // draws nothing until that task has loaded the card
        HStack(spacing: 0) {
            Color.clear.frame(width: 0, height: 0)
            if let c = ev.card(target.id), c.request != nil, c.manifest != nil {
                let judged = c.status?.judged == true && c.status?.stands != false
                HStack(spacing: 6) {
                    Text("evidence").foregroundStyle(theme.inkDim)
                    Text("\(c.fields.count) field\(c.fields.count == 1 ? "" : "s")")
                    if let g = c.manifest?.gaps, !g.isEmpty { Text("· \(g.count) not captured").foregroundStyle(theme.inkFaint) }
                    Text(c.current != true ? "· older code" : c.status?.stands == false ? "· verdict void" : judged ? "· \(c.status?.verdict == "accept" ? "accepted" : "rejected")" : "· unjudged")
                        .foregroundStyle(c.current != true || c.status?.stands == false ? theme.ember : judged ? (c.status?.verdict == "accept" ? theme.patina : theme.ember) : theme.goldLeaf)
                    Text(",e").foregroundStyle(theme.inkFaint)
                }
                .font(Theme.mono(11.5))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5).fill(theme.vellumRaise))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(theme.vellumEdge))
                .labelTarget(pane: "evidence-chip", key: "open")
            }
        }
        .task(id: "\(target.id)|\(app.store.view(Branch.self, target.id)?.tip ?? "")|\(ev.generation)") {
            await ev.loadCard(app, target)
        }
    }
}

struct EvidencePanel: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    let target: ReviewPageState.Target

    static let tileWidth: CGFloat = 300
    static let pictureHeight: CGFloat = 70
    static let gap: CGFloat = 10

    var body: some View {
        let ev = EvidenceState.of(app)
        let c = ev.card(target.id)
        VStack(alignment: .leading, spacing: 12) {
            if let c {
                header(c)
                if let m = c.manifest {
                    strip(c, m, ev)
                    if ev.zoomed, let f = selectedField(c) {
                        enlarged(c, m, f, ev)
                    }
                    sheet(c, m, ev)
                }
            } else {
                Text("reading evidence…").foregroundStyle(theme.inkFaint)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: "\(target.id)|\(app.store.view(Branch.self, target.id)?.tip ?? "")|\(ev.generation)") {
            await ev.load(app, target)
            while !Task.isCancelled, ev.card(target.id)?.run?.running == true || ev.card(target.id)?.waiting == true {
                try? await Task.sleep(for: .seconds(ev.card(target.id)?.waiting == true ? 10 : 2))
                await ev.load(app, target)
            }
        }
    }

    private func selectedField(_ c: EvidenceCard) -> EvidenceCard.Field? {
        let key = app.isFocused(evidencePane) ? app.selected : nil
        return c.fields.first { "e|\($0.id)" == key } ?? c.fields.first
    }

    @ViewBuilder private func header(_ c: EvidenceCard) -> some View {
        if c.request == nil {
            Text(c.error ?? c.err ?? "No evidence request for this branch — one lives at ~/.dotfiles/evidence/requests/\(target.repo)/\(target.name).json")
                .foregroundStyle(theme.inkDim)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text(c.manifest?.expectation ?? c.request?.expectation ?? "")
                    .font(Theme.text(13)).foregroundStyle(theme.inkDim)
                    .padding(.leading, 10)
                    .overlay(alignment: .leading) { theme.goldDeep.frame(width: 2) }
                if let w = c.claimWords {
                    Text(w).font(Theme.mono(11)).foregroundStyle(theme.inkFaint)
                }
                if c.manifest?.retrospective == true, let asked = c.manifest?.captured {
                    Text("re-explained after capture — the captures were predicted as: \(asked.expectation)")
                        .font(Theme.text(12)).foregroundStyle(theme.ember)
                }
                if let why = c.why, !why.isEmpty {
                    Text("can't be judged: " + why.joined(separator: "; ")).font(Theme.text(12)).foregroundStyle(theme.ember)
                }
                if let run = c.run, run.running {
                    Text("rendering… \(run.tail?.last ?? "")").font(Theme.mono(11)).foregroundStyle(theme.goldDeep)
                } else if c.waiting == true {
                    Text("waiting for another evidence run to finish, then renders this").font(Theme.mono(11)).foregroundStyle(theme.goldDeep)
                } else if let run = c.run, let code = run.exit, code != 0 {
                    Text("the last render failed: \(run.tail?.last ?? "exit \(code)")").font(Theme.mono(11)).foregroundStyle(theme.ember)
                } else if c.manifest == nil {
                    Text("nothing rendered yet — ,R renders it").foregroundStyle(theme.inkFaint)
                } else if c.current != true {
                    Text("rendered for an older version of this branch — ,R renders it again").foregroundStyle(theme.ember)
                } else if c.available == false {
                    Text("these images are gone from the cache — ,R renders them again").foregroundStyle(theme.ember)
                }
            }
        }
    }

    /// The counts in words for the variant on screen, what isn't covered, and the outcome.
    @ViewBuilder private func strip(_ c: EvidenceCard, _ m: EvidenceCard.Manifest, _ ev: EvidenceState) -> some View {
        let v = ev.variant(c)
        let scenes = c.fields.compactMap { $0.scenes[v] }.compactMap { c.finding($0) }
        let itself = scenes.filter { $0.changed && !$0.departure }.count
        let around = scenes.filter { $0.departure }.count
        let same = scenes.filter { !$0.changed && $0.moved != true && !$0.departure }.count
        let gaps = m.gaps ?? []
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 22) {
                count(itself, "changed only themselves", theme.patina)
                if around > 0 { count(around, "changed something around them", theme.goldLeaf) }
                if same > 0 { count(same, "unchanged", theme.inkDim) }
                if !gaps.isEmpty { count(gaps.count, "not captured", theme.inkFaint) }
                Spacer(minLength: 12)
                verdict(c)
            }
            HStack(spacing: 8) {
                ForEach(Array(c.variants.enumerated()), id: \.offset) { i, x in
                    Text(x.title.isEmpty ? "as rendered" : x.title)
                        .font(Theme.mono(11.5))
                        .foregroundStyle(x.id == v ? theme.ink : theme.inkFaint)
                        .padding(.horizontal, 9).padding(.vertical, 2)
                        .overlay(Capsule().stroke(x.id == v ? theme.goldLeaf : theme.rule))
                        .help("space \(i + 1)")
                }
                Text(ev.alone.map { "showing all \($0)" } ?? "before above after · ,t flips all").font(Theme.mono(11)).foregroundStyle(ev.alone == nil ? theme.inkFaint : theme.goldLeaf)
                    .padding(.leading, 6)
                Spacer()
                Text("\(m.findings.count) scenes · before \(m.basis.beforeCommit.prefix(8)) → after \(m.basis.afterCommit.prefix(8))")
                    .font(Theme.mono(11)).foregroundStyle(theme.inkFaint)
            }
            if let cov = m.coverage {
                let names = cov.uncovered.map { ($0 as NSString).lastPathComponent + ((cov.unverified ?? []).contains($0) ? " (named by a view, unchecked)" : "") }
                Text("looks at \(cov.covered.count) of \(cov.changed.count) changed UI files"
                     + (names.isEmpty ? "" : " · accepting also accepts, unseen: " + names.joined(separator: ", ")))
                    .font(Theme.text(11.5)).foregroundStyle(names.isEmpty ? theme.inkFaint : theme.goldLeaf).fixedSize(horizontal: false, vertical: true)
            }
            if !gaps.isEmpty {
                Text("why: " + gaps.joined(separator: " · ")).font(Theme.text(11.5)).foregroundStyle(theme.inkFaint).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func count(_ n: Int, _ what: String, _ color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(n)").font(Theme.mono(19, weight: .semibold)).foregroundStyle(color)
            Text(what).font(Theme.text(13)).foregroundStyle(theme.inkDim)
        }
    }

    @ViewBuilder private func verdict(_ c: EvidenceCard) -> some View {
        if let s = c.status, s.judged {
            let word = (s.verdict == "accept" ? "accepted" : "rejected") + (s.stands == false ? " — no longer stands" : "")
            Text(s.carriedFrom != nil ? "\(word) · identical to what you judged \(s.at?.prefix(10) ?? "")" : "\(word) \(s.at?.prefix(10) ?? "")")
                .font(Theme.text(12)).foregroundStyle(s.verdict == "accept" && s.stands != false ? theme.patina : theme.ember)
        } else if EvidenceState.of(app).shown(c) {
            Text("accept ,y   reject ,N").font(Theme.mono(12)).foregroundStyle(theme.goldLeaf)
        } else if c.manifest != nil {
            Text("not judged").font(Theme.text(12)).foregroundStyle(theme.inkFaint)
        }
    }

    /// Every field as a tile, the sheet the cursor walks: j/k a row, h/l a tile, ret enlarges.
    @ViewBuilder private func sheet(_ c: EvidenceCard, _ m: EvidenceCard.Manifest, _ ev: EvidenceState) -> some View {
        let v = ev.variant(c)
        let cursor = app.isFocused(evidencePane) ? app.selected : nil
        GeometryReader { geo in
            let cols = max(1, Int((geo.size.width + Self.gap) / (Self.tileWidth + Self.gap)))
            let w = (geo.size.width - Self.gap * CGFloat(cols - 1)) / CGFloat(cols)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(w), spacing: Self.gap), count: cols),
                              alignment: .leading, spacing: Self.gap) {
                        ForEach(c.fields, id: \.id) { f in
                            tile(c, m, f, v, width: w, on: "e|\(f.id)" == cursor, ev).id("e|\(f.id)")
                        }
                    }
                }
                .onChange(of: cursor) { _, k in if let k { proxy.scrollTo(k) } }
            }
            .onAppear { ev.columns = cols }
            .onChange(of: cols) { _, n in ev.columns = n }
        }
    }

    private func tile(_ c: EvidenceCard, _ m: EvidenceCard.Manifest, _ f: EvidenceCard.Field, _ v: String, width: CGFloat, on: Bool, _ ev: EvidenceState) -> some View {
        let iw = width - 12
        let scene = f.scenes[v]
        let finding = scene.flatMap { c.finding($0) }
        let bs = scene.flatMap { m.before.scenes[$0] }, asha = scene.flatMap { m.after.scenes[$0] }
        // both pictures cut to the same region: the field on either side, with a margin of its surroundings
        let boxes = [scene.flatMap { m.before.fields?[$0] }, scene.flatMap { m.after.fields?[$0] }].compactMap { $0 }.filter { $0.count == 4 }
        let region: CGRect? = boxes.isEmpty ? nil : boxes.map { CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) }
            .reduce(CGRect.null) { $0.union($1) }.insetBy(dx: -40, dy: -32)
        let before = bs.flatMap { ev.around($0, region) }, after = asha.flatMap { ev.around($0, region) }
        let mark = finding.map { $0.departure ? "●" : $0.changed ? "✓" : "=" } ?? "·"
        let markColor = finding?.departure == true ? theme.goldLeaf : finding?.changed == true ? theme.patina : theme.inkFaint
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Text(mark).foregroundStyle(markColor)
                Text(f.title).foregroundStyle(on ? theme.ink : theme.inkDim).lineLimit(1)
            }
            .font(Theme.text(12, weight: on ? .semibold : .regular))
            switch ev.alone {
            case "before"?: picture(before, "before", iw, Self.pictureHeight * 2 + 4)
            case "after"?: picture(after, "after", iw, Self.pictureHeight * 2 + 4)
            default:
                picture(before, "before", iw, Self.pictureHeight)
                picture(after, "after", iw, Self.pictureHeight)
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 7).fill(on ? theme.goldWash : theme.vellumRaise))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(on ? theme.goldLeaf : theme.vellumEdge, lineWidth: on ? 1.5 : 1))
        .labelTarget(pane: evidencePane, key: "e|\(f.id)")
    }

    /// One side's crop, fitted and centred in its slot, with the side named in its corner.
    private func picture(_ img: NSImage?, _ side: String, _ w: CGFloat, _ h: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            theme.vellumNight
            if let img, img.size.width > 0 {
                Image(nsImage: img).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                    .frame(width: w, height: h)
            }
            Text(side).font(Theme.mono(9.5)).foregroundStyle(theme.inkFaint)
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(theme.vellumNight.opacity(0.8))
        }
        .frame(width: w, height: h)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    /// The selected field enlarged: a wipe, before left of the seam and after right of it, or its
    /// changed pixels lit, with what the measurements say.
    @ViewBuilder private func enlarged(_ c: EvidenceCard, _ m: EvidenceCard.Manifest, _ f: EvidenceCard.Field, _ ev: EvidenceState) -> some View {
        let v = ev.variant(c)
        let scene = f.scenes[v] ?? ""
        let bs = m.before.scenes[scene], asha = m.after.scenes[scene]
        let before = bs.flatMap { ev.images[$0] }, after = asha.flatMap { ev.images[$0] }
        let natural = (after ?? before).map { $0.size.width / 2 } ?? 600
        let w = min(natural * 1.5, 900)
        let h = (after ?? before).map { w * $0.size.height / $0.size.width } ?? 200
        HStack(alignment: .top, spacing: 20) {
            ZStack(alignment: .topLeading) {
                if ev.changes, let bs, let asha, let lit = ev.heat(bs, asha) {
                    Image(nsImage: lit).resizable().interpolation(.high).frame(width: w, height: h)
                } else {
                    if let after { Image(nsImage: after).resizable().interpolation(.high).frame(width: w, height: h) }
                    if let before {
                        Image(nsImage: before).resizable().interpolation(.high).frame(width: w, height: h)
                            .mask(alignment: .leading) { Rectangle().frame(width: w * ev.seam) }
                    }
                    theme.goldLeaf.frame(width: 2, height: h).offset(x: w * ev.seam - 1)
                    HStack {
                        Text("before"); Spacer(); Text("after")
                    }
                    .font(Theme.mono(11)).foregroundStyle(theme.goldLeaf).padding(8).frame(width: w)
                }
            }
            .frame(width: w, height: h)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.vellumEdge))
            VStack(alignment: .leading, spacing: 8) {
                Text(f.title).font(Theme.display(16))
                ForEach(c.facts(scene), id: \.self) { Text($0).font(Theme.text(13)).foregroundStyle(theme.inkDim) }
                Text(ev.changes ? "changed pixels lit · ,c for the wipe" : "h/l move the seam · ,c lights what changed")
                    .font(Theme.mono(11)).foregroundStyle(theme.inkFaint).padding(.top, 6)
                Text("esc back to every field").font(Theme.mono(11)).foregroundStyle(theme.inkFaint)
            }
            .frame(maxWidth: 320, alignment: .leading)
        }
        .padding(.bottom, 4)
    }
}
