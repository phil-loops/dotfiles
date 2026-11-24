import CanopyCore
import Foundation
import Observation

@MainActor
@Observable
final class BenchOpening {
    private struct Request {
        let number: Int
        let subject: BenchSubject
        let epoch: String
        let git: Int?
        var reader: ReaderContext
    }

    @ObservationIgnored private weak var app: AppModel?
    private var sequence = 0
    private var pending: Request?
    @ObservationIgnored private(set) var task: Task<Void, Never>?
    @ObservationIgnored var openDocument: (URL) async throws -> Void = ShowDocument.open

    private init(_ app: AppModel) { self.app = app }
    static func of(_ app: AppModel) -> BenchOpening { app.state { BenchOpening(app) } }

    var waiting: Bool { pending.map { current($0) } ?? false }

    func cancel() {
        sequence &+= 1
        pending = nil
        task?.cancel()
        task = nil
    }

    private func current(_ request: Request, afterPicker: Bool = false) -> Bool {
        guard let app, sequence == request.number, BenchSubject.current(app) == request.subject,
              app.store.epoch == request.epoch, app.store.versions[Domain.git] == request.git else { return false }
        return afterPicker ? request.reader.isCurrentAfterPickerChoice(app) : request.reader.isCurrent(app) && app.keys.active == .normal
    }

    func open() {
        guard let app, let subject = BenchSubject.current(app) else { return }
        cancel()
        let request = Request(number: sequence, subject: subject, epoch: app.store.epoch,
                              git: app.store.versions[Domain.git], reader: ReaderContext(app))
        let io = BenchLibrary.of(app).io
        pending = request
        app.runner.say("finding the bench…")
        task = Task { @MainActor [weak self] in
            guard let self, current(request) else { return }
            let worker = Task.detached(priority: .utility) { Result { try io.documents(for: subject) } }
            let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard current(request), !Task.isCancelled else { return }
            guard case .success(let documents) = result else {
                pending = nil
                return app.runner.say("couldn't read the bench library")
            }
            guard !documents.isEmpty else {
                pending = nil
                return app.runner.say("no bench names this branch or forest")
            }
            if documents.count == 1 { return await finish(documents[0], request, io) }
            var choice = request
            app.nav.pick("open bench", documents.map { PickItem(label: $0.title, text: $0.url.path) }) { [weak self] index in
                MainActor.assumeIsolated {
                    guard let self, documents.indices.contains(index), self.current(choice, afterPicker: true), let app = self.app else { return }
                    var selected = choice
                    selected.reader = ReaderContext(app)
                    self.pending = selected
                    self.task = Task { @MainActor [weak self] in await self?.finish(documents[index], selected, io) }
                }
            }
            choice.reader = ReaderContext(app)
            pending = choice
        }
    }

    private func finish(_ document: BenchDocument, _ request: Request, _ io: BenchIO) async {
        guard let app, current(request), !Task.isCancelled else { return }
        defer { if pending?.number == request.number { pending = nil } }
        let valid = await Task.detached(priority: .utility) { io.validate(document, for: request.subject) }.value
        guard current(request), !Task.isCancelled else { return }
        guard valid else { return app.runner.say("bench changed; open it again to choose its current definition") }
        pending = nil
        do {
            try await openDocument(document.url)
            if current(request) { app.runner.say("opened \(document.title) in Show") }
        } catch {
            if current(request) { app.runner.say("couldn't open the bench in Show") }
        }
    }

    static func install(_ app: AppModel) {
        for scope in [Scope.review, .forest] {
            app.registry.register(Command(id: "bench.open.\(scope.rawValue)", title: "Open the branch or forest's bench in Show", scope: scope,
                budget: .local, leader: LocalKey(",T"), label: "bench", group: .show,
                available: { [weak app] _ in app.flatMap(BenchSubject.current) != nil },
                local: { [weak app] _, _ in if let app { Self.of(app).open() } }))
        }
        app.registry.register(Command(id: "bench.refresh", title: "Refresh recorded bench results", scope: .global, budget: .local,
            available: { [weak app] _ in app.flatMap(BenchSubject.current) != nil },
            local: { [weak app] _, _ in
                guard let app, let subject = BenchSubject.current(app) else { return }
                Task {
                    guard BenchSubject.current(app) == subject else { return }
                    await BenchLibrary.of(app).load(subject)
                }
            }))
        app.addCloser(first: true, isOpen: { [weak app] in app.map { Self.of($0).waiting } ?? false }, close: { [weak app] in
            guard let app else { return }
            _ = Self.backOut(app)
        })
    }

    static func backOut(_ app: AppModel) -> Bool {
        let opening = Self.of(app)
        guard opening.waiting else { return false }
        opening.cancel()
        app.runner.say("bench opening cancelled")
        return true
    }
}
