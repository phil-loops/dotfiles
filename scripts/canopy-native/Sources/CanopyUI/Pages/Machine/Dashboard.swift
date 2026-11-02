import CanopyCore
import Observation
import SwiftUI

// Dashboard.tsx: where to focus next — every command and surface against its budget, most used and
// never used, refusals, the weekly trend, and v1 beside v2, all from GET /telemetry/summary.

struct Stats: Decodable, Equatable { var n: Int; var p50: Double?; var p95: Double? }

struct BudgetMs: Decodable, Equatable { var feedbackMs: Double; var settledMs: Double? }

/// One command's (or surface's) row; `pairs` reuses it for both sides, so every field is optional
/// beyond the id.
struct TelemetryRow: Decodable, Equatable {
    var app: String?
    var id: String?
    var budget: String?
    var budgetMs: BudgetMs?
    var n: Int
    var via: [String: Int]?
    var refusedRate: Double?
    var failedRate: Double?
    var topErr: String?
    var feedback: Stats?
    var settled: Stats?
    var paint: Stats?
    var over: Double?
    /// a v1 side that never ran gives just the ids it counted
    var ids: [String]?
}

struct Pair: Decodable, Equatable {
    /// "cmd" | "nav"
    var kind: String
    var id: String
    var v1ids: [String]
    var v2: TelemetryRow?
    var v1: TelemetryRow?
}

struct Week: Decodable, Equatable { var week: String; var app: String; var cmds: Int; var feedbackP95: Double?; var settledP95: Double?; var paintP95: Double? }

struct PageHealth: Decodable, Equatable { var loads: Int; var longtasks: Int; var longtaskMsP95: Double?; var clsP95: Double? }

struct Used: Decodable, Equatable { var app: String; var id: String; var n: Int }

struct Summary: Decodable, Equatable {
    var days: Int
    var paintMs: Double
    var commands: [TelemetryRow]
    var surfaces: [TelemetryRow]
    var mostUsed: [Used]
    var neverUsed: [String]
    var pairs: [Pair]
    var weekly: [Week]
    var pages: [String: PageHealth]
    var ms: Double
}

enum DashText {
    static func ms(_ v: Double?) -> String {
        guard let v else { return "—" }
        return v >= 1000 ? String(format: "%.1fs", v / 1000) : "\(Int(v.rounded()))ms"
    }

    static func pct(_ v: Double?) -> String {
        guard let v, v != 0 else { return "—" }
        return "\(Int((v * 100).rounded()))%"
    }

    /// p95 against its budget: nil when either is missing.
    static func ratio(_ value: Double?, _ budget: Double?) -> Double? {
        guard let value, let budget, budget != 0 else { return nil }
        return value / budget
    }

    static func verdict(_ r: Double) -> String { r > 1 ? String(format: "✕ %.1f×", r) : "✓ in" }
}

/// The dashboard's window and what the server answered for it (ui.ts dashDays + the resource).
@MainActor
@Observable
final class DashboardState {
    static let ranges = [7, 30, 90]
    var days = 30
    private(set) var summary: Summary?
    private(set) var failed = false
    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored private var asked = 0

    init(app: AppModel) { self.app = app }

    func cycle() { days = Self.ranges[((Self.ranges.firstIndex(of: days) ?? 0) + 1) % Self.ranges.count] }

    func take(_ s: Summary) { summary = s; failed = false }

    /// Read the window `days` names; a newer ask wins over an older answer.
    func load() async {
        guard let t = app?.transport else { return }
        asked += 1
        let mine = asked, d = days
        summary = nil
        failed = false
        do {
            let s = try await t.getJSON("/telemetry/summary?days=\(d)", as: Summary.self)
            if mine == asked { summary = s }
        } catch {
            if mine == asked { failed = true }
        }
    }

    // ── the panes: each table's rows, so j/k walk them and C-w j/k step between tables ──

    struct Panel { var id: String; var title: String; var rows: [String]; var column = 0; var row: Int }

    var panels: [Panel] {
        guard let s = summary else { return [] }
        return [
            Panel(id: "commands", title: "commands", rows: s.commands.prefix(25).indices.map { "cmd:\($0)" }, row: 0),
        ].filter { !$0.rows.isEmpty }
    }
}

@MainActor
enum DashboardCommands {
    static func install(_ app: AppModel) {
        let d = app.state { DashboardState(app: app) }
        app.registry.register(Command(id: "dashboard.range", title: "Change the dashboard's window", scope: .dashboard, leader: LocalKey(",r"), label: "range",
                                      local: { [weak d] _, _ in d?.cycle() }))
    }
}

struct DashboardSurface: SurfaceProvider {
    let surfaceID = "dashboard"

    func view(_ app: AppModel, route: Route) -> AnyView { AnyView(DashboardPage()) }

    func panes(_ app: AppModel) -> [Pane] {
        let ps = app.state { DashboardState(app: app) }.panels
        if ps.isEmpty { return [Pane(id: "commands", rows: [])] }
        return ps.map { Pane(id: $0.id, title: $0.title, rows: $0.rows, column: $0.column, row: $0.row, pageSize: 12) }
    }
}

private let TH: (String) -> Text = { Text($0.uppercased()).font(Theme.text(10.5)).tracking(1) }

struct DashboardPage: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        let d = app.state { DashboardState(app: app) }
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text("Where to focus").font(Theme.display(26)).foregroundStyle(theme.ink)
                Button { app.runner.dispatch("dashboard.range", via: .click) } label: {
                    Text("last \(d.days) days · \(app.registry.keyOf("dashboard.range")) to change").foregroundStyle(theme.inkFaint)
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 20)
            if let s = d.summary {
                FollowScroll(panes: d.panels.map(\.id)) {
                    VStack(alignment: .leading, spacing: 36) {
                        commands(s)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 16)
                }
            } else {
                Text(d.failed ? "couldn't read the telemetry" : "reading the telemetry…").foregroundStyle(theme.inkFaint)
            }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: d.days) { await d.load() }
    }

    private func commands(_ s: Summary) -> some View {
        Panel(title: "Commands over budget, worst first", pane: "commands") {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 20, verticalSpacing: 0) {
                GridRow {
                    TH("command"); TH("runs"); TH("p95"); TH("vs one frame")
                }
                .foregroundStyle(theme.inkFaint)
                ForEach(Array(s.commands.prefix(25).enumerated()), id: \.offset) { i, c in
                    let key = "cmd:\(i)"
                    let on = app.isFocused("commands") && app.selected == key
                    GridRow {
                        Text(c.id ?? "").foregroundStyle(on ? theme.goldLeaf : theme.ink)
                        Text("\(c.n)")
                        Text(DashText.ms(c.feedback?.p95))
                        Meter(value: c.feedback?.p95, budget: c.budgetMs?.feedbackMs)
                    }
                    .background(on ? theme.goldWash : .clear)
                    .id(key)
                    // what v2 kept in hover titles: the budget and the top refusal, on the cursor row
                    if on {
                        GridRow {
                            Text(cmdDetail(c)).foregroundStyle(theme.inkDim).gridCellColumns(4)
                        }
                    }
                }
            }
        }
    }

    private func cmdDetail(_ c: TelemetryRow) -> String {
        var bits = ["budget: feedback \(DashText.ms(c.budgetMs?.feedbackMs)) · settled \(DashText.ms(c.budgetMs?.settledMs))"]
        if (c.settled?.n ?? 0) > 0 { bits.append("settled p95 \(DashText.ms(c.settled?.p95))") }
        if let r = c.refusedRate, r > 0 { bits.append("refused \(DashText.pct(r))") }
        if let f = c.failedRate, f > 0 { bits.append("failed \(DashText.pct(f))") }
        if let via = c.via, !via.isEmpty { bits.append("via " + via.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")) }
        if let e = c.topErr { bits.append("top refusal: \(e)") }
        return "↳ " + bits.joined(separator: " · ")
    }

}

/// A titled table; its body is the pane `pane`, ringed while focused.
private struct Panel<Content: View>: View {
    @Environment(\.theme) private var theme
    let title: String
    var note: String?
    let pane: String
    @ViewBuilder let content: () -> Content

    init(title: String, note: String? = nil, pane: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title; self.note = note; self.pane = pane; self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(Theme.display(19)).foregroundStyle(theme.ink)
            if let note { Text(note).foregroundStyle(theme.inkFaint).padding(.bottom, 8) }
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) { content() }.padding(4)
            }
            .paneRing(pane)
        }
        .font(Theme.text(12))
    }
}

/// p95 against its budget: a bar to 2× budget, the budget tick at the middle, a word for status.
private struct Meter: View {
    @Environment(\.theme) private var theme
    let value: Double?
    let budget: Double?

    var body: some View {
        if let r = DashText.ratio(value, budget) {
            HStack(spacing: 8) {
                ZStack(alignment: .leading) {
                    theme.vellumEdge.frame(width: 96, height: 6)
                    (r > 1 ? theme.ember : theme.patina).frame(width: 96 * min(1, r / 2), height: 6)
                    theme.inkFaint.frame(width: 1, height: 10).offset(x: 48)
                }
                Text(DashText.verdict(r)).foregroundStyle(r > 1 ? theme.ember : theme.inkFaint)
            }
        } else {
            Text("—").foregroundStyle(theme.inkFaint)
        }
    }
}
