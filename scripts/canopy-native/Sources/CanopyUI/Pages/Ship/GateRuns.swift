import CanopyCore
import Foundation

/// A branch's gates run as the server pushes it (srv/state.py `gaterun`, git domain): the one copy
/// the forest row, the strip and the door all read (one fact, one owner, one copy; 2026-11-17).
/// No view polls for it. Only the run for the branch's current tree is this branch's progress: an
/// older tree's finished run is history, so `p` over a new commit reads as "gates starting", never
/// as the last run's verdict.
enum GateRuns {
    /// The run the store holds for the branch, whatever tree it gated (`tree` says which).
    @MainActor static func pushed(_ app: AppModel, _ id: String) -> GateProgress? {
        guard let obj = app.store.rawView("gaterun", id), obj["tree"]?.string != nil,
              let data = try? JSONEncoder().encode(JSONValue.object(obj)),
              var p = try? JSONDecoder().decode(GateProgress.self, from: data) else { return nil }
        if p.running, let started = obj["started"]?.number { p.elapsed = max(0, Date().timeIntervalSince1970 - started) }
        return p
    }

    /// The pushed run, only when it gated the branch's current tree.
    @MainActor static func progress(_ app: AppModel, _ id: String) -> GateProgress? {
        guard let b = app.store.view(Branch.self, id), let p = pushed(app, id), p.tree == b.tree else { return nil }
        return p
    }
}

struct GateProgressSummary: Equatable {
    let rows: [GateRow]
    let complete: Int
    let activity: String
    let time: String?

    init(_ progress: GateProgress, now: Double) {
        rows = GatesRun.rows(progress, now: now)
        complete = rows.filter { [.green, .red, .waived].contains($0.state) }.count
        if let running = rows.first(where: { $0.state == .running }) {
            activity = "\(running.name)\(GatesRun.stuck(rows) != nil ? " · quiet" : "")"
            time = running.ms.map { GatesRun.secs($0) }
        } else if let failed = rows.first(where: { $0.state == .red }) {
            activity = "\(failed.name) failed"
            time = nil
        } else if progress.dead == true || rows.contains(where: { $0.state == .stopped }) {
            activity = "stopped"
            time = nil
        } else if GatesRun.isRunning(progress) {
            let setup = GatesRun.setup(progress)
            switch setup?.step {
            case "queue": activity = setup?.position.map { "queued #\($0)" } ?? "queued"
            case "checkout": activity = "preparing checkout"
            case "env": activity = "repairing environment"
            default: activity = rows.first(where: { $0.state == .queued }).map { "\($0.name) next" } ?? "starting"
            }
            time = setup?.ts.map { GatesRun.secs(max(0, now - $0) * 1000) } ?? progress.elapsed.map { GatesRun.secs($0 * 1000) }
        } else {
            activity = rows.isEmpty ? "no steps reported" : "last run finished"
            time = nil
        }
    }
}
