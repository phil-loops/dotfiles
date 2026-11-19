import CanopyTestSupport
import Foundation
import Testing
@testable import CanopyCore

/// Every wait goes through one clock, so what a timer does is stated in time, not raced against it.
@MainActor @Suite struct SchedulerTests {
    @Test func dueWorkRunsInOrderAndNeverEarly() {
        let clock = ManualScheduler()
        var ran: [String] = []
        clock.after(2) { ran.append("b") }
        clock.after(1) { ran.append("a") }
        clock.after(1) { ran.append("a2") }
        clock.advance(by: 0.99)
        #expect(ran.isEmpty)
        clock.advance(by: 0.01)
        #expect(ran == ["a", "a2"], "same instant: the order they were asked for")
        clock.advance(by: 5)
        #expect(ran == ["a", "a2", "b"] && clock.waiting == 0)
    }

    @Test func workScheduledByWorkRunsWhenItsTimeComesInTheSameAdvance() {
        let clock = ManualScheduler()
        var ran: [Double] = []
        let t0 = clock.now
        clock.after(1) { ran.append(clock.now.timeIntervalSince(t0)); clock.after(1) { ran.append(clock.now.timeIntervalSince(t0)) } }
        clock.advance(by: 3)
        #expect(ran == [1, 2])
    }

    @Test func aNoteLastsFourSecondsAndANewerOneKeepsItsOwn() {
        let clock = ManualScheduler()
        let transport = Transport(base: URL(string: "http://127.0.0.1:1")!)
        let runner = Runner(registry: CommandRegistry(), store: Store(), transport: transport,
                            telemetry: Telemetry(transport: transport, enabled: false), scheduler: clock)
        runner.say("first")
        clock.advance(by: 3)
        runner.say("second")
        clock.advance(by: 1.5)
        #expect(runner.note == "second", "the first note's expiry doesn't take the newer one")
        clock.advance(by: 2.5)
        #expect(runner.note == nil)
    }

    @Test func telemetryFlushesThreeSecondsAfterItsFirstEvent() async throws {
        let clock = ManualScheduler()
        let t = Telemetry(transport: Transport(base: URL(string: "http://127.0.0.1:1")!), enabled: true, scheduler: clock)
        t.emit(["type": "cmd", "id": "x"])
        #expect(clock.waiting == 1)
        clock.advance(by: 2.9)
        #expect(clock.waiting == 1, "not yet")
        clock.advance(by: 0.1)
        #expect(clock.waiting == 0, "flushed")
    }
}
