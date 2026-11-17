import CanopyCore
import Foundation

@MainActor
final class ForestAncestry {
    private struct Request {
        let number: Int
        let branch: Branch
        let epoch: String
        let git: Int?
        var reader: ReaderContext
    }

    private struct Reply: Decodable {
        let branch: String
        let requires: [String]?
        let ok: Bool?
        let err: String?
        let error: String?
    }

    private weak var app: AppModel?
    private var sequence = 0
    private var pending: Request?
    private(set) var task: Task<Void, Never>?

    private init(_ app: AppModel) { self.app = app }
    static func of(_ app: AppModel) -> ForestAncestry { app.state { ForestAncestry(app) } }

    var waiting: Bool { pending.map { current($0) } ?? false }

    func cancel() {
        sequence &+= 1
        pending = nil
        task?.cancel()
        task = nil
    }

    private func current(_ request: Request, afterPicker: Bool = false) -> Bool {
        guard let app, sequence == request.number, app.store.epoch == request.epoch,
              app.store.versions[Domain.git] == request.git, ForestNav.here(app)?.b == request.branch else { return false }
        return afterPicker ? request.reader.isCurrentAfterPickerChoice(app) : request.reader.isCurrent(app) && app.keys.active == .normal
    }

    func open(_ branch: Branch) {
        guard let app else { return }
        cancel()
        let request = Request(number: sequence, branch: branch, epoch: app.store.epoch,
                              git: app.store.versions[Domain.git], reader: ReaderContext(app))
        pending = request
        app.runner.say("reading what \(branch.name) builds on…")
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if self.pending?.number == request.number { self.pending = nil } }
            guard current(request) else { return }
            let reply: Reply
            do {
                reply = try await app.transport.getJSON(app.transport.atRepo(branch.repo, "/node?branch=\(branch.name.uriComponent)"))
            } catch {
                if current(request) { app.runner.say("couldn't read what \(branch.name) builds on") }
                return
            }
            guard current(request) else { return }
            guard reply.branch == branch.name, reply.ok != false, (reply.err ?? "").isEmpty, (reply.error ?? "").isEmpty else {
                app.runner.say("couldn't read what \(branch.name) builds on")
                return
            }
            guard let requires = reply.requires else {
                app.runner.say("dependency edges aren't available from this server")
                return
            }
            let order = ForestNav.mergeOrder(app)
            if let missing = requires.first(where: { name in !order.contains { $0.b.name == name } }) {
                app.runner.say("\(missing) isn't shown in this forest")
                return
            }
            var seen = Set<String>()
            let deps = ([branch.parent] + requires).compactMap { name -> BranchView? in
                guard seen.insert(name).inserted else { return nil }
                return order.first { $0.b.name == name }
            }
            guard !deps.isEmpty else { return app.runner.say("\(branch.name) has no parent or dependency shown in this forest") }
            if deps.count == 1 { return ForestNav.go(deps[0], app) }
            var choice: Request?
            app.nav.pick("builds on · \(deps.count)", deps.map {
                PickItem(label: $0.b.name, text: ($0.b.name == branch.parent ? "parent" : "requires") + ($0.b.description.isEmpty ? "" : " · \($0.b.description)"))
            }) { [weak self, weak app] index in
                MainActor.assumeIsolated {
                    guard let self, let app, let choice, self.current(choice, afterPicker: true), deps.indices.contains(index),
                          let target = ForestNav.mergeOrder(app).first(where: { $0.b.id == deps[index].b.id }) else { return }
                    ForestNav.go(target, app)
                }
            }
            choice = request
            choice?.reader = ReaderContext(app)
        }
    }
}
