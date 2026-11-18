import CanopyCore

extension ReviewPageState {
    func warmEditor(_ app: AppModel) {
        guard editorWarmEnabled, integration == nil, !scoped, let target,
              let command = app.registry.command("review.helix.land"), app.runner.refusal?(command) == nil else { return }
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
            guard self.target?.id == target.id, (epoch.isEmpty || app.store.epoch == epoch),
                  app.runner.refusal?(command) == nil else {
                editorWarmRepos.remove(key)
                warmEditor(app)
                return
            }
            let _: JSONValue? = await app.transport.ask(app.transport.atRepo(target.repo, "/edit-warm"), body)
        }
    }
}
