import CanopyCore
import Foundation

@MainActor
final class EditorPreparation {
    let source: BranchSource
    let base: String
    let session = UUID().uuidString.lowercased()
    let owner = UUID().uuidString.lowercased()
    private(set) var task: Task<HelixWhere?, Never>!
    private(set) var answer: HelixWhere?
    private var released = false
    private var releaseTask: Task<Void, Never>?

    init(_ app: AppModel, source: BranchSource, base: String, path: String, after predecessor: Task<Void, Never>?) {
        self.source = source
        self.base = base
        task = Task { @MainActor [weak self, weak app] in
            await predecessor?.value
            guard let self, let app, !released else { return nil }
            let body: JSONObject = ["branch": .string(source.name), "session": .string(session), "viewOwner": .string(owner),
                "expectedTip": .string(source.tip), "baseSha": .string(base), "epoch": .string(source.epoch), "leaseProtocol": 1,
                "entry": ["path": .string(path), "line": 1, "col": 1]]
            let result = await app.transport.ask(app.transport.atRepo(source.repo, "/edit-session"), body, as: HelixWhere.self)
            answer = result
            return result
        }
    }

    func matches(_ source: BranchSource, base: String) -> Bool { !released && self.source.sameBranch(as: source) && self.base == base }

    @discardableResult func release(_ app: AppModel) -> Task<Void, Never> {
        if let releaseTask { return releaseTask }
        released = true
        let body: JSONObject = ["session": .string(session), "viewOwner": .string(owner)]
        let path = app.transport.atRepo(source.repo, "/edit-release")
        let transport = app.transport
        let task = Task { @MainActor in
            let _: JSONValue? = await transport.ask(path, body)
        }
        releaseTask = task
        return task
    }
}

extension ReviewPageState {
    func releaseEditorPreparation(_ app: AppModel) {
        guard let preparation = editorPreparation else { return }
        editorPreparation = nil
        editorReleaseTask = preparation.release(app)
    }

    func warmEditor(_ app: AppModel) {
        let source = BranchSource.current(app, id)
        let saving = app.runner.runOf("review.helix.land", id).map(\.inFlight) == true
        let permitted = editorWarmEnabled && app.router.route.surfaceID == "review" && integration == nil && !scoped
            && !saving
            && app.registry.command("review.helix.land").map { app.runner.refusal?($0) == nil } == true
        func current(_ preparation: EditorPreparation) -> Bool {
            permitted && diffCurrent && source.map { preparation.matches($0, base: baseSha) } == true
        }
        if let preparation = editorPreparation, !current(preparation) {
            releaseEditorPreparation(app)
        }
        if let preparation = helixPreparation, !current(preparation) { cancelHelixPreparation() }
        guard permitted, helix == nil, let target else { return }
        if diffCurrent, let source, HelixLanding.fullObject(source.tip), HelixLanding.fullObject(baseSha),
           let path = payload?.data.files.first?.path {
            if editorPreparation == nil {
                editorPreparation = EditorPreparation(app, source: source, base: baseSha, path: path, after: editorReleaseTask)
            }
            return
        }
        let epoch = app.store.epoch
        let initial = "initial|\(target.repo)"
        let key = epoch.isEmpty ? initial : "\(epoch)|\(target.repo)"
        if !epoch.isEmpty, editorWarmRepos.remove(initial) != nil {
            editorWarmRepos.insert(key)
            return
        }
        guard editorWarmRepos.insert(key).inserted else { return }
        var body = ["branch": target.name]
        if !epoch.isEmpty { body["epoch"] = epoch }
        if let source = BranchSource.current(app, id), HelixLanding.fullObject(source.tip) { body["expectedTip"] = source.tip }
        Task { @MainActor [weak app, weak self] in
            guard let app, let self else { return }
            guard editorWarmEnabled, self.target?.id == target.id, (epoch.isEmpty || app.store.epoch == epoch),
                  app.registry.command("review.helix.land").map({ app.runner.refusal?($0) == nil }) == true else {
                editorWarmRepos.remove(key)
                warmEditor(app)
                return
            }
            let _: JSONValue? = await app.transport.ask(app.transport.atRepo(target.repo, "/edit-warm"), body)
        }
    }
}
