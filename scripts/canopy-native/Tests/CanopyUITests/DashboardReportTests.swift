import Foundation
import Testing
@testable import CanopyUI

struct DashboardReportTests {
    func row(_ id: String? = "cursor.down", app: String? = "native", n: Int = 100,
             feedback: Stats? = Stats(n: 5, p50: 3, p95: 10), settled: Stats? = nil) -> TelemetryRow {
        TelemetryRow(app: app, id: id, budgetMs: BudgetMs(feedbackMs: 16.7, settledMs: 300), n: n, feedback: feedback, settled: settled)
    }

    @Test func filtersRetainTheProducerOrderWithoutCombiningClientsOrDroppingRowsBeforeFiltering() {
        let old = (0..<30).map { row("old.\($0)", app: "v2") }
        let report = DashboardReport(old + [row("current"), row("older", app: "v1"), row("missing", app: nil)])
        #expect(report.rows(for: .app("native")).map(\.name) == ["current"])
        #expect(report.rows(for: .app("v2")).count == 30)
        #expect(report.rows(for: .all).map(\.name) == old.map { $0.id! } + ["current", "older", "missing"])
        #expect(report.clients == [.app("native"), .app("v1"), .app("v2"), .unattributed, .all])
        #expect(DashboardReport(old).clients.contains(.app("native")))
    }

    @Test func commandIdentitySurvivesRankingAndIncludesTheExactClient() throws {
        let native = try #require(DashboardCommand(row()))
        let old = try #require(DashboardCommand(row(app: "v2")))
        #expect(native.id != old.id)
        let reordered = DashboardReport([row("other"), row()])
        #expect(reordered.rows(for: .all).last?.id == native.id)
        let a = try #require(DashboardCommand(row("b:c", app: "a")))
        let b = try #require(DashboardCommand(row("c", app: "a:b")))
        #expect(a.id != b.id)
        #expect(DashboardCommand(row("cursor.😀", app: "😀"))?.id == DashboardCommand(row("cursor.😀", app: "😀"))?.id)
    }

    @Test func ambiguousAndUnnamedRowsAreWithheldInsteadOfReceivingRankIdentities() {
        let report = DashboardReport([row(), row(), row(""), row(nil), row("valid", app: "v2")])
        #expect(report.withheld == 4)
        #expect(report.commands.map(\.name) == ["valid"])
        let unknown = DashboardReport([row(app: nil), row(app: "?")])
        #expect(unknown.commands.isEmpty && unknown.withheld == 2)
    }

    @Test func eachPhaseRetainsItsOwnSupportAndBudgetInsteadOfTheExecutionCount() throws {
        let command = try #require(DashboardCommand(row(settled: Stats(n: 2, p50: 500, p95: 900))))
        #expect(command.source.n == 100)
        #expect(command.feedback.samples == 5 && command.feedback.support == "n=5")
        #expect(command.settled.samples == 2 && command.settled.support == "n=2")
        #expect(command.feedback.ratio! < 1 && command.settled.ratio == 3)
        let empty = DashboardTiming(Stats(n: 0, p50: 1, p95: 1), budget: 16.7)
        #expect(empty.support == "no samples" && empty.p95 == nil && empty.ratio == nil)
    }

    @Test func invalidOrMissingSupportCannotBecomeAWithinBudgetMeasurement() {
        for n in [-1, 0] {
            let phase = DashboardTiming(Stats(n: n, p50: 0, p95: 0), budget: 16.7)
            #expect(phase.p95 == nil && phase.ratio == nil)
        }
        #expect(DashboardTiming(nil, budget: 16.7).support == "samples unavailable")
        #expect(DashboardTiming(Stats(n: -1), budget: 16.7).support == "samples unavailable")
        for p95 in [Double.nan, .infinity, -.infinity, -1] {
            let phase = DashboardTiming(Stats(n: 3, p95: p95), budget: 16.7)
            #expect(phase.samples == 3 && phase.p95 == nil && phase.ratio == nil)
            #expect(DashText.ms(p95) == "—")
        }
        for budget in [Double.nan, .infinity, -.infinity, -1, 0] {
            let phase = DashboardTiming(Stats(n: 3, p95: 10), budget: budget)
            #expect(phase.p95 == 10 && phase.budget == nil && phase.ratio == nil)
        }
        #expect(DashText.ratio(.greatestFiniteMagnitude, .leastNonzeroMagnitude) == nil)
        #expect(DashText.verdict(.nan) == "—")
        #expect(DashText.pct(.nan) == "—" && DashText.pct(-1) == "—" && DashText.pct(2) == "—")
        #expect(DashboardTiming(Stats(n: 1, p95: 0), budget: 16.7).ratio == 0)
    }
}
