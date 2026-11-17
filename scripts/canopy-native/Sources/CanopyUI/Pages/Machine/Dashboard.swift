import CanopyCore
import Observation
import SwiftUI

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
    /// the first keys after a page open, the rest, and each surface's own wait
    var cold: Stats?
    var warm: Stats?
    var surfaces: [String: Stats]?
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
        guard let v, v.isFinite, v >= 0 else { return "—" }
        return v >= 1000 ? String(format: "%.6gs", v / 1000) : String(format: "%.6gms", v)
    }

    static func pct(_ v: Double?) -> String {
        guard let v, v.isFinite, (0...1).contains(v) else { return "—" }
        return "\(Int((v * 100).rounded()))%"
    }

    /// p95 against its budget: nil when either is missing.
    static func ratio(_ value: Double?, _ budget: Double?) -> Double? {
        guard let value, let budget, value.isFinite, value >= 0, budget.isFinite, budget > 0 else { return nil }
        let result = value / budget
        return result.isFinite ? result : nil
    }

    static func verdict(_ r: Double) -> String {
        guard r.isFinite, r >= 0 else { return "—" }
        if r <= 1 { return "✓ in" }
        if r < 1.05 { return "✕ >1×" }
        return r >= 1000 ? String(format: "✕ %.2g×", r) : String(format: "✕ %.1f×", r)
    }
}

/// The dashboard's window and what the server answered for it (ui.ts dashDays + the resource).
@MainActor
@Observable
final class DashboardState {
    static let ranges = [7, 30, 90]
    private(set) var days = 30
    private(set) var windowRevision = 0
    private(set) var summary: Summary?
    private(set) var failed = false
    private(set) var client: DashboardClient = .app("native")
    private(set) var report = DashboardReport([])
    @ObservationIgnored var read: (Int) async throws -> Summary
    @ObservationIgnored private var asked = 0

    init(app: AppModel) {
        let transport = app.transport
        read = { days in try await transport.getJSON("/telemetry/summary?days=\(days)", as: Summary.self) }
    }

    func cycle() {
        windowRevision += 1
        asked += 1
        days = Self.ranges[((Self.ranges.firstIndex(of: days) ?? 0) + 1) % Self.ranges.count]
        summary = nil
        failed = false
    }

    func cycleClient() {
        let clients = report.clients
        client = clients[((clients.firstIndex(of: client) ?? -1) + 1) % clients.count]
    }

    var commands: [DashboardCommand] { Array(report.rows(for: client).prefix(25)) }

    func take(_ s: Summary) { summary = s; report = DashboardReport(s.commands); failed = false }

    /// Read the window `days` names; a newer ask wins over an older answer.
    func load() async {
        guard !Task.isCancelled else { return }
        asked += 1
        let mine = asked, d = days
        summary = nil
        failed = false
        do {
            let s = try await read(d)
            guard !Task.isCancelled, mine == asked, days == d else { return }
            guard s.days == d else { failed = true; return }
            take(s)
        } catch {
            if !Task.isCancelled, mine == asked, days == d { failed = true }
        }
    }

    struct Panel { var id: String; var title: String; var rows: [String]; var column = 0; var row: Int }

    var panels: [Panel] {
        guard summary != nil else { return [] }
        return [
            Panel(id: "commands", title: "commands", rows: commands.map(\.id), row: 0),
        ].filter { !$0.rows.isEmpty }
    }
}

@MainActor
enum DashboardCommands {
    static func install(_ app: AppModel) {
        let d = app.state { DashboardState(app: app) }
        app.registry.register(Command(id: "dashboard.range", title: "Change the dashboard's window", scope: .dashboard, leader: LocalKey(",r"), label: "range",
                                      local: { [weak d] _, _ in d?.cycle() }))
        app.registry.register(Command(id: "dashboard.client", title: "Change the dashboard client", scope: .dashboard, leader: LocalKey(",c"), label: "client",
                                      local: { [weak d] _, _ in d?.cycleClient() }))
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

struct DashboardPage: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        let d = app.state { DashboardState(app: app) }
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text("Where to focus").font(Theme.display(26)).foregroundStyle(theme.ink)
                Spacer(minLength: 8)
                Lever(id: "dashboard.client", word: d.client.title)
                Lever(id: "dashboard.range", word: "\(d.days) days")
            }
            .padding(.bottom, 20)
            if d.summary != nil {
                FollowScroll(panes: d.panels.map(\.id)) {
                    VStack(alignment: .leading, spacing: 36) {
                        commands(d)
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
        .task(id: d.windowRevision) { await d.load() }
    }

    private func commands(_ d: DashboardState) -> some View {
        let total = d.report.rows(for: d.client).count
        let note = "Ranked by usage and budget overrun" + (total > 25 ? " · showing 25 of \(total)" : "")
        return Panel(title: "Command timings", note: note, pane: "commands") {
            VStack(alignment: .leading, spacing: 14) {
                if d.commands.isEmpty {
                    Text("No command timings for \(d.client.title) in this window").foregroundStyle(theme.inkFaint)
                }
                if d.report.withheld > 0 {
                    Text("\(d.report.withheld) unnamed or duplicate rows unavailable").foregroundStyle(theme.ember)
                }
                ForEach(d.commands) { command in
                    CursorRow(pane: "commands", key: command.id) { on in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text(command.name).foregroundStyle(on ? theme.goldLeaf : theme.ink)
                                Text(command.client.title).foregroundStyle(theme.inkFaint)
                                Spacer(minLength: 8)
                                Text(command.source.n >= 0 ? "\(command.source.n) executions" : "executions unavailable")
                                    .foregroundStyle(theme.inkDim).fixedSize(horizontal: true, vertical: false)
                            }
                            ViewThatFits(in: .horizontal) {
                                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 4) {
                                    timing("feedback p95", command.feedback)
                                    timing("settled p95", command.settled)
                                }
                                .fixedSize(horizontal: true, vertical: false)
                                VStack(alignment: .leading, spacing: 8) {
                                    narrowTiming("feedback p95", command.feedback)
                                    narrowTiming("settled p95", command.settled)
                                }
                            }
                            if on { Text(cmdDetail(command.source)).foregroundStyle(theme.inkDim).fixedSize(horizontal: false, vertical: true) }
                        }
                        .padding(.horizontal, 8).padding(.vertical, 6)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .cursorMarks("commands")
        }
    }

    private func timing(_ name: String, _ phase: DashboardTiming) -> some View {
        GridRow {
            Text(name).foregroundStyle(theme.inkDim)
            Text(DashText.ms(phase.p95))
            Text(phase.support).foregroundStyle(theme.inkFaint)
            Text("budget \(DashText.ms(phase.budget))").foregroundStyle(theme.inkFaint)
            Meter(value: phase.p95, budget: phase.budget).fixedSize(horizontal: true, vertical: false)
        }
    }

    private func narrowTiming(_ name: String, _ phase: DashboardTiming) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(name).foregroundStyle(theme.inkDim)
                Text(DashText.ms(phase.p95))
                Spacer(minLength: 4)
                Text("budget \(DashText.ms(phase.budget))").foregroundStyle(theme.inkFaint)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(phase.support).foregroundStyle(theme.inkFaint)
                Spacer(minLength: 4)
                Meter(value: phase.p95, budget: phase.budget).fixedSize(horizontal: true, vertical: false)
            }
        }
    }

    private func cmdDetail(_ c: TelemetryRow) -> String {
        var bits: [String] = []
        if let cold = c.cold, cold.n > 0, let warm = c.warm, warm.n > 0 {
            bits.append("cold feedback p95 \(DashText.ms(DashboardTiming(cold, budget: nil).p95)) (\(cold.n)) · warm \(DashText.ms(DashboardTiming(warm, budget: nil).p95)) (\(warm.n))")
        }
        if let s = c.surfaces, s.count > 1 {
            bits.append(s.sorted { ($0.value.p95 ?? 0) > ($1.value.p95 ?? 0) }.prefix(3)
                .map { "\($0.key) \(DashText.ms(DashboardTiming($0.value, budget: nil).p95)) (n=\($0.value.n))" }.joined(separator: ", "))
        }
        if let r = c.refusedRate, r > 0 { bits.append("refused \(DashText.pct(r))") }
        if let f = c.failedRate, f > 0 { bits.append("failed \(DashText.pct(f))") }
        if let via = c.via, !via.isEmpty { bits.append("via " + via.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")) }
        if let e = c.topErr { bits.append("top refusal: \(e)") }
        return bits.joined(separator: " · ")
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
            VStack(alignment: .leading, spacing: 0) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
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
