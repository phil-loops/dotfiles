import Foundation

/// When delayed work runs, and what time it is: the app's one clock. The app runs it on the main
/// queue; a test's moves only when the test advances it, so no assertion races a real timer (a note
/// expiring mid-test under load, 2026-11-18). Everything that waits — a note's expiry, a write's
/// settle give-up, telemetry's flush, a forest's closing moment, a re-poll — waits through this.
@MainActor public protocol Scheduler: AnyObject {
    var now: Date { get }
    func after(_ seconds: TimeInterval, _ work: @escaping @MainActor () -> Void)
}

@MainActor public final class MainScheduler: Scheduler {
    nonisolated public init() {}
    public var now: Date { Date() }
    public func after(_ seconds: TimeInterval, _ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { MainActor.assumeIsolated { work() } }
    }
}

/// Time that moves only on `advance(by:)`: due work runs in the order it falls due, each at its own time.
@MainActor public final class ManualScheduler: Scheduler {
    public private(set) var now: Date
    private var pending: [(at: Date, seq: Int, work: @MainActor () -> Void)] = []
    private var seq = 0

    public init(now: Date = Date(timeIntervalSince1970: 1_800_000_000)) { self.now = now }

    /// how many delayed jobs wait
    public var waiting: Int { pending.count }

    public func after(_ seconds: TimeInterval, _ work: @escaping @MainActor () -> Void) {
        seq += 1
        pending.append((now.addingTimeInterval(seconds), seq, work))
    }

    public func advance(by seconds: TimeInterval) {
        let end = now.addingTimeInterval(seconds)
        while let i = pending.indices.filter({ pending[$0].at <= end })
            .min(by: { (pending[$0].at, pending[$0].seq) < (pending[$1].at, pending[$1].seq) }) {
            let job = pending.remove(at: i)
            now = max(now, job.at)
            job.work()
        }
        now = end
    }
}
