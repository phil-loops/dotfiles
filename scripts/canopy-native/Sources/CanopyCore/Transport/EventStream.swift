import Foundation

/// The live store — a port of sync.ts's second half: hydrate from /state (the first time, or when
/// told to resync), then hold /v2/events open, applying each patch. A gap or a `resync` event
/// refetches /state and reconnects; an error marks the store down and retries with backoff
/// (0.5s doubling to 10s, reset on `hello`).
@MainActor
public final class EventStream {
    public let transport: Transport
    public let store: Store
    /// The server's build signature moved (hello / asset) — keys.toml was saved, or the web app
    /// was rebuilt. The app re-reads the bootstrap and re-applies keys.
    public var onAsset: ((String) -> Void)?
    /// Every frame, after it's handled (debug dump, tests).
    public var onFrame: ((SSEFrame) -> Void)?
    public var count: ((String, Double?) -> Void)?

    public private(set) var stats: [String: Int] = [:]
    public private(set) var lastAsset = ""
    private var task: Task<Void, Never>?
    private var backoff: Double = 0.5

    public init(transport: Transport, store: Store) {
        self.transport = transport
        self.store = store
    }

    public var running: Bool { task != nil }

    public func connect() {
        guard task == nil else { return }
        task = Task { [weak self] in await self?.run() }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    /// Drop the stream and hydrate again (sync.ts resync).
    public func resync() {
        stop()
        bump("resync")
        task = Task { [weak self] in await self?.run(refetch: true) }
    }

    private func bump(_ name: String, _ ms: Double? = nil) {
        stats[name, default: 0] += 1
        count?(name, ms)
    }

    private enum End { case resync, closed }

    private func run(refetch first: Bool = false) async {
        var refetch = first
        while !Task.isCancelled {
            do {
                if refetch || !store.ready {
                    try await load()
                    refetch = false
                }
                switch try await stream() {
                case .resync:
                    bump("resync")
                    refetch = true
                    continue
                case .closed:
                    throw HTTPError(path: "/v2/events", status: 0)
                }
            } catch {
                if Task.isCancelled { return }
                store.conn = .down
                bump("reconnect")
                try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
                backoff = min(backoff * 2, 10)
            }
        }
    }

    private func load() async throws {
        let t0 = Date()
        let data = try await transport.getData("/state")
        let snap = try Snapshot.decode(data)
        store.hydrate(snap)
        bump("state", Date().timeIntervalSince(t0) * 1000)
    }

    private func path() -> String {
        let v = store.versions
        let domains = Set(v.keys).union([Domain.git, Domain.remote, Domain.review, Domain.todo]).sorted()
        let q = domains.map { "\($0)=\(v[$0] ?? 0)" }.joined(separator: "&")
        return "/v2/events?epoch=\(store.epoch.uriComponent)&\(q)"
    }

    private func stream() async throws -> End {
        for try await f in try await transport.events(path()) {
            if Task.isCancelled { return .closed }
            defer { onFrame?(f) }
            switch f.event {
            case "hello":
                backoff = 0.5
                store.conn = .live
                bump("hello")
                asset(f.json?["asset"]?.string)
            case "asset":
                asset(f.json?["asset"]?.string)
            case "patch":
                guard let p = try? Patch.decode(Data(f.data.utf8)) else { bump("patch-undecodable"); return .resync }
                let res = store.applyPatch(p)
                bump(res == .ok ? "patch" : "patch-\(res.rawValue)")
                if res == .gap { return .resync }
            case "resync":
                return .resync
            default:
                break
            }
        }
        return .closed
    }

    private func asset(_ a: String?) {
        guard let a, !a.isEmpty else { return }
        let moved = !lastAsset.isEmpty && a != lastAsset
        lastAsset = a
        if moved { onAsset?(a) }
    }
}

/// The server's pulse (GET /events, v1's stream): it says `procs` when a preview, agent or chat turn
/// moves — things that aren't store domains. Held open only while something listens (sync.ts onProcs).
@MainActor
public final class Pulse {
    private let transport: Transport
    private var fns: [Int: () -> Void] = [:]
    private var next = 0
    private var task: Task<Void, Never>?

    public init(transport: Transport) { self.transport = transport }

    /// Call `fn` whenever a preview, agent or chat turn moves; returns the unsubscribe.
    public func onProcs(_ fn: @escaping () -> Void) -> () -> Void {
        next += 1
        let k = next
        fns[k] = fn
        open()
        return { [weak self] in
            guard let self else { return }
            self.fns[k] = nil
            if self.fns.isEmpty { self.task?.cancel(); self.task = nil }
        }
    }

    private func fire() { for fn in fns.values { fn() } }

    private func open() {
        guard task == nil, !fns.isEmpty else { return }
        task = Task { [weak self] in
            var backoff = 0.5
            while !Task.isCancelled {
                do {
                    guard let t = self?.transport else { return }
                    for try await f in try await t.events("/events") where f.event == "procs" {
                        backoff = 0.5
                        self?.fire()
                    }
                } catch {}
                if Task.isCancelled { return }
                try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
                backoff = min(backoff * 2, 10)
            }
        }
    }
}
