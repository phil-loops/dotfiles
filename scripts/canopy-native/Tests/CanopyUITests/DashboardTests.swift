import CanopyCore
import Foundation
import Testing
@testable import CanopyUI

@MainActor private final class DashboardReads {
    var days: [Int] = []
    var replies: [CheckedContinuation<Summary, Error>] = []
    func read(_ days: Int) async throws -> Summary {
        try await withCheckedThrowingContinuation { reply in self.days.append(days); replies.append(reply) }
    }
}

@MainActor struct DashboardTests {
    func app() -> (AppModel, DashboardState) {
        var config = AppConfig(); config.route = .dashboard
        let app = AppModel(config: config, port: 1, telemetry: false)
        return (app, app.state { DashboardState(app: app) })
    }

    func summary(days: Int = 30, commands: [TelemetryRow]? = nil) throws -> Summary {
        var summary = try JSONDecoder().decode(Summary.self, from: Data(MachineFixtures.summary.utf8))
        summary.days = days
        if let commands { summary.commands = commands }
        return summary
    }

    @Test func keyedClientChoiceFiltersBeforeTheLimitAndKeepsCurrentCommandAcrossReordering() throws {
        let (app, dashboard) = app(), rows = DashboardReportTests()
        let native = rows.row("current"), other = rows.row("other")
        dashboard.take(try summary(commands: (0..<30).map { rows.row("old.\($0)", app: "v2") } + [native, other]))
        #expect(dashboard.client == .app("native"))
        #expect(dashboard.commands.map(\.name) == ["current", "other"])
        app.keys.handle("j")
        let selected = app.selected
        dashboard.take(try summary(commands: [other, native]))
        #expect(app.selected == selected)
        dashboard.take(try summary(commands: [other, native, rows.row("old", app: "v2")]))
        app.keys.handle(","); app.keys.handle("c")
        #expect(dashboard.client == .app("v2") && dashboard.commands.map(\.name) == ["old"])
        app.keys.handle(","); app.keys.handle("c")
        #expect(dashboard.client == .all && dashboard.commands.count == 3)
        app.keys.handle(","); app.keys.handle("c")
        #expect(dashboard.client == .app("native") && app.selected == selected)
        #expect(KeyboardRule.violations(app) { $0.hasPrefix("dashboard.") }.isEmpty)
        #expect(app.registry.keyProblems.isEmpty)
    }

    @Test func changingWindowsRevokesTheOldSummaryBeforeTheNextLoadEvenAcrossARoundTrip() async throws {
        let (_, dashboard) = app(), held = DashboardReads()
        dashboard.read = held.read
        dashboard.take(try summary())
        let old = Task { await dashboard.load() }
        await until("held dashboard") { held.replies.count == 1 }
        let firstRevision = dashboard.windowRevision
        dashboard.cycle()
        #expect(dashboard.days == 90 && dashboard.summary == nil)
        dashboard.cycle(); dashboard.cycle()
        #expect(dashboard.days == 30 && dashboard.windowRevision == firstRevision + 3)
        held.replies[0].resume(returning: try summary())
        await old.value
        #expect(dashboard.summary == nil && !dashboard.failed)
        let current = Task { await dashboard.load() }
        await until("new dashboard") { held.replies.count == 2 }
        held.replies[1].resume(returning: try summary())
        await current.value
        #expect(dashboard.summary?.days == 30 && !dashboard.failed)
        dashboard.cycle()
        #expect(dashboard.summary == nil)
    }

    @Test func cancelledTransportThatStillReturnsCannotPublishSuccessOrFailure() async throws {
        for success in [true, false] {
            let (_, dashboard) = app(), held = DashboardReads()
            dashboard.read = held.read
            let task = Task { await dashboard.load() }
            await until("held dashboard") { held.replies.count == 1 }
            task.cancel()
            if success { held.replies[0].resume(returning: try summary()) }
            else { held.replies[0].resume(throwing: CocoaError(.fileReadUnknown)) }
            await task.value
            #expect(dashboard.summary == nil && !dashboard.failed)
        }
    }

    @Test func newerLoadOwnsTheSameWindowAndMismatchedServerWindowIsUnavailable() async throws {
        let (_, dashboard) = app(), held = DashboardReads()
        dashboard.read = held.read
        let old = Task { await dashboard.load() }
        await until("old dashboard") { held.replies.count == 1 }
        let new = Task { await dashboard.load() }
        await until("new dashboard") { held.replies.count == 2 }
        var current = try summary(); current.ms = 42
        held.replies[1].resume(returning: current)
        await new.value
        held.replies[0].resume(throwing: CocoaError(.fileReadUnknown))
        await old.value
        #expect(dashboard.summary?.ms == 42 && !dashboard.failed)
        let wrong = Task { await dashboard.load() }
        await until("wrong window") { held.replies.count == 3 }
        held.replies[2].resume(returning: try summary(days: 7))
        await wrong.value
        #expect(dashboard.summary == nil && dashboard.failed)
    }
}
