import CanopyCore
import Foundation

@MainActor
final class ReviewGitHubOpening {
    struct Target {
        let ref: String
        let path: String
        let lines: ClosedRange<Int>
    }

    private struct Request {
        let number: Int
        let source: BranchSource
        let trunk: String
        let reader: ReaderContext
    }

    private weak var app: AppModel?
    private var sequence = 0
    private var pending: Request?
    private(set) var task: Task<Void, Never>?

    private init(_ app: AppModel) { self.app = app }
    static func of(_ app: AppModel) -> ReviewGitHubOpening { app.state { ReviewGitHubOpening(app) } }

    private func current(_ request: Request) -> Bool {
        guard let app, pending?.number == request.number, sequence == request.number, !Task.isCancelled,
              request.reader.isCurrent(app), BranchSource.current(app, request.source.id) == request.source,
              app.store.view(Repo.self, request.source.repo)?.main == request.trunk else { return false }
        return ReviewPageState.of(app).diffCurrent
    }

    func open(_ target: Target, source: BranchSource, trunk: String) {
        guard let app else { return }
        cancel()
        let request = Request(number: sequence, source: source, trunk: trunk, reader: ReaderContext(app))
        pending = request
        task = Task { @MainActor in
            defer { if pending?.number == request.number { pending = nil } }
            guard current(request) else { return }
            let web = await ReviewPageState.of(app).githubPage(app, source: source)
            guard current(request) else { return }
            guard let web else { return app.runner.say("couldn't read origin's GitHub address for \(source.repo)") }
            let path = target.path.split(separator: "/").map { String($0).uriComponent }.joined(separator: "/")
            let fragment = target.lines.count > 1 ? "#L\(target.lines.lowerBound)-L\(target.lines.upperBound)" : "#L\(target.lines.lowerBound)"
            guard let url = URL(string: "\(web)/blob/\(target.ref.uriComponent)/\(path)\(fragment)") else {
                return app.runner.say("couldn't form the GitHub address")
            }
            pending = nil
            ShipState.of(app).openURL(url)
        }
    }

    func cancel() {
        sequence &+= 1
        pending = nil
        task?.cancel()
        task = nil
    }

    static func backOut(_ app: AppModel) -> Bool {
        let opening = Self.of(app)
        guard let request = opening.pending, opening.current(request) else { return false }
        opening.cancel()
        app.runner.say("GitHub opening cancelled")
        return true
    }
}
