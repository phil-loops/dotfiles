import AppKit
import CanopyCore
import Foundation
import Observation

/// The machine (workstation.ts): the dev servers this workstation runs, the one shared substrate
/// (the Docker stack) they all ride, and what the tooling costs the box. Read while the page is
/// open, refreshed when the pulse's `procs` signal says a preview moved; the footprint and an open
/// log have no signal, so those two poll.
@MainActor
@Observable
final class Workstation {
    enum LogSource: String { case web, jobs }

    private(set) var servers: [Server] = []
    private(set) var substrate: Substrate?
    private(set) var footprint: Footprint?
    private(set) var logFor: String?
    private(set) var logSrc: LogSource = .web
    private(set) var log: String?
    var mainPort = "3000"
    /// what a swapped port served before, so it can swing back
    var swapped: [String: (dir: String, label: String)] = [:]
    /// a kill (or kill all, or reap) readied by its first press (ui.ts armed)
    var armed: String?

    /// How `machine.open` opens a server's url; tests swap it so nothing leaves the process.
    @ObservationIgnored public var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }

    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored private var reading = false
    @ObservationIgnored private var again = false
    @ObservationIgnored private var watchers = 0
    @ObservationIgnored private var stops: [() -> Void] = []

    init(app: AppModel) { self.app = app }

    func server(_ id: String?) -> Server? { id.flatMap { id in servers.first { $0.sid == id } } }
    /// the server for the literal main branch, wherever it landed — not whatever squats :3000
    var main: Server? { servers.first { $0.branch == "main" } }

    /// Take a read the page didn't fetch (tests; a future push of the same shape).
    func take(_ p: Previews) {
        servers = p.previews ?? []
        substrate = p.substrate
        app?.store.nudge()
    }

    func take(_ f: Footprint) { footprint = f }

    func take(log text: String) { log = text }

    /// Re-read the servers; a call while one is out queues exactly one more.
    func refresh() {
        if reading { again = true; return }
        guard let t = app?.transport else { return }
        reading = true
        Task { @MainActor [weak self] in
            if let r = try? await t.getJSON("/previews", as: Previews.self) { self?.take(r) }
            guard let self else { return }
            self.reading = false
            if self.again { self.again = false; self.refresh() }
        }
    }

    func measure() {
        guard let t = app?.transport else { return }
        Task { @MainActor [weak self] in
            if let f = try? await t.getJSON("/footprint", as: Footprint.self) { self?.footprint = f }
        }
    }

    func tail() {
        let id = logFor, src = logSrc
        guard let s = server(id), let t = app?.transport else { return }
        let path = "/preview-log?dir=\(s.dir.uriComponent)\(src == .jobs ? "&which=jobs" : "")"
        Task { @MainActor [weak self] in
            guard let r = try? await t.getJSON(path, as: PreviewLog.self), let self, self.logFor == id, self.logSrc == src else { return }
            let text = (r.log ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            self.log = text.isEmpty ? "(log empty)" : text
        }
    }

    func showLog(_ id: String?, _ src: LogSource = .web) {
        log = nil
        logSrc = src
        logFor = id
        tail()
    }

    /// The open log's lines (its pane's rows), the last 400.
    var logLines: [String] {
        guard let log else { return [] }
        return Array(log.split(separator: "\n", omittingEmptySubsequences: false).suffix(400).map(String.init))
    }

    /// Hold the page live while it's on screen: read now, follow the procs signal, poll the
    /// footprint (15 s) and an open log (1.5 s). Balanced by the returned stop.
    func watch() -> () -> Void {
        watchers += 1
        if watchers == 1, let app {
            refresh()
            measure()
            let off = app.pulse.onProcs { [weak self] in Task { @MainActor in self?.refresh() } }
            let fp = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 15_000_000_000)
                    self?.measure()
                }
            }
            let lg = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    self?.tail()
                }
            }
            stops = [off, { fp.cancel() }, { lg.cancel() }]
        }
        var stopped = false
        return { [weak self] in
            guard let self, !stopped else { return }
            stopped = true
            self.watchers -= 1
            if self.watchers == 0 { self.stops.forEach { $0() }; self.stops = [] }
        }
    }
}
