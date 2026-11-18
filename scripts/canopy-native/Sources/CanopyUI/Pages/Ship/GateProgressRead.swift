import CanopyCore
import Foundation
import Observation

@MainActor @Observable final class GateProgressRead {
    struct Source: Hashable, Sendable {
        let repo: String
        let branch: String
        let tip: String
        let tree: String

        init(_ branch: Branch) {
            repo = branch.repo; self.branch = branch.name; tip = branch.tip; tree = branch.tree
        }

        init(repo: String, branch: String, tip: String, tree: String) {
            self.repo = repo; self.branch = branch; self.tip = tip; self.tree = tree
        }
    }

    enum Status: Equatable {
        case loading, unavailable, observed(GateProgress)
    }

    private var source: Source?
    private var status = Status.loading
    private var revision: UInt64 = 0

    func status(for source: Source) -> Status { self.source == source ? status : .loading }

    func watch(_ source: Source, read: (Source) async throws -> GateProgress,
               pause: () async throws -> Void = { try await Task.sleep(nanoseconds: 2_000_000_000) }) async {
        guard !Task.isCancelled else { return }
        revision &+= 1
        let ticket = revision
        self.source = source
        status = .loading
        while !Task.isCancelled && revision == ticket {
            do {
                let progress = try await read(source)
                guard !Task.isCancelled, revision == ticket else { return }
                status = .observed(progress)
            } catch {
                guard !Task.isCancelled, revision == ticket else { return }
                status = .unavailable
            }
            do { try await pause() } catch { return }
        }
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
