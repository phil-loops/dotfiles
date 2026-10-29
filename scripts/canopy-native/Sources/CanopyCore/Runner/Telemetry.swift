import Foundation

/// The telemetry sink (telemetry.ts): schema-2 events batched to POST /track every 3s, plus one
/// `page` aggregate of high-frequency counters per launch. Events carry `app: "native"` so the
/// dashboard can tell this client from the web one. Only the Runner, the Router hook and the
/// EventStream call it — pages don't.
@MainActor
public final class Telemetry {
    public static let schema = 2
    public static let app = "native"

    private let transport: Transport
    /// Off in --dump runs and tests: nothing is posted.
    public var enabled: Bool
    private var queue: [JSONObject] = []
    private var timer: DispatchWorkItem?
    private var counters: [String: Int] = [:]
    private var timings: [String: [Double]] = [:]

    public init(transport: Transport, enabled: Bool = true) {
        self.transport = transport
        self.enabled = enabled
    }

    public func emit(_ ev: JSONObject) {
        guard enabled else { return }
        var e: JSONObject = ["schema": .number(Double(Self.schema)), "app": .string(Self.app), "pl": .string(transport.pageLoad)]
        e.merge(ev) { $1 }
        queue.append(e)
        if timer == nil {
            let w = DispatchWorkItem { [weak self] in self?.flush() }
            timer = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: w)
        }
    }

    /// Count a high-frequency fact (a patch, a resync) into this launch's aggregate.
    public func count(_ name: String, _ ms: Double? = nil) {
        counters[name, default: 0] += 1
        if let ms { timings[name, default: []].append(ms.rounded()) }
    }

    public func flush() {
        timer?.cancel()
        timer = nil
        guard enabled, !queue.isEmpty else { return }
        let body: JSONValue = ["type": "batch", "events": .array(queue.map(JSONValue.object))]
        queue.removeAll()
        let t = transport
        Task.detached { _ = await t.post("/track", body) }
    }

    /// The launch's aggregate, then a flush — on quit or when the app goes to the background.
    public func flushPage(route: String) {
        if !counters.isEmpty {
            let tm: JSONObject = timings.mapValues { v in
                let s = v.sorted()
                return ["n": .number(Double(s.count)), "p50": .number(s[s.count / 2]), "max": .number(s.last ?? 0)]
            }
            emit(["type": "page", "route": .string(route), "counters": .object(counters.mapValues { .number(Double($0)) }), "timings": .object(tm)])
        }
        counters = [:]
        timings = [:]
        flush()
    }

    public var snapshot: [String: Int] { counters }
}
