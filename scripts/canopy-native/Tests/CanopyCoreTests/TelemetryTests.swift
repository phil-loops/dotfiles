import Foundation
import Testing
@testable import CanopyCore

/// A command event says where it happened and how long after the page opened, so the dashboard
/// can tell a cold key (the page's first paint) from a steady-state stall.
@Suite struct TelemetryTests {
    @MainActor private func make() -> Telemetry {
        Telemetry(transport: Transport(base: URL(string: "http://127.0.0.1:1")!), enabled: false)
    }

    @Test @MainActor func aCommandCarriesItsSurfaceAndTimeSinceThePageOpened() {
        let t = make()
        let opened = Date(timeIntervalSince1970: 1000)
        t.arrived("review", at: opened)
        let e = t.stamped(["type": "cmd", "id": "cursor.down"], now: opened.addingTimeInterval(0.3))
        #expect(e["surface"] == .string("review"))
        #expect(e["sinceNavMs"] == .number(300))
    }

    @Test @MainActor func beforeAnyPageNothingIsStamped() {
        let e = make().stamped(["type": "cmd", "id": "cursor.down"])
        #expect(e["surface"] == nil)
        #expect(e["sinceNavMs"] == nil)
    }

    @Test @MainActor func otherEventsPassThrough() {
        let t = make()
        t.arrived("forest")
        let e = t.stamped(["type": "nav", "to": "review"])
        #expect(e["surface"] == nil)
    }
}
