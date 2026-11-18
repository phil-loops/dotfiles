import CanopyCore
import Foundation

@MainActor enum EditorRecovery {
    struct Entry: Decodable {
        let path: String
        let line: Int
        let col: Int

        var valid: Bool {
            line > 0 && col > 0 && !path.isEmpty && path.split(separator: "/", omittingEmptySubsequences: false)
                .allSatisfy { !["", ".", ".."].contains(String($0)) }
        }
    }

    struct Workspace: Decodable {
        let session: String
        let branch: String
        let expectedTip: String
        let baseSha: String
        let operation: String?
        let sha: String?
        let message: String?
        let retryable: Bool
        let resumable: Bool?
        let entry: Entry?

        func matches(_ source: BranchSource) -> Bool {
            retryable && branch == source.name && UUID(uuidString: session) != nil
                && operation.flatMap(UUID.init(uuidString:)) != nil && HelixLanding.fullObject(expectedTip)
                && HelixLanding.fullObject(baseSha) && sha.map(HelixLanding.fullObject) == true
        }

        func canResume(_ source: BranchSource, base: String) -> Bool {
            resumable == true && !retryable && branch == source.name && expectedTip == source.tip && baseSha == base
                && UUID(uuidString: session) != nil && entry?.valid == true
        }
    }

    struct Catalog: Decodable {
        let ok: Bool
        let epoch: String
        let workspaces: [Workspace]
    }

    struct Request {
        let workspace: Workspace
        let source: BranchSource
        let reader: ReaderContext
    }

    static func install(_ app: AppModel) {
        for (id, title, resuming) in [("review.helix.recover", "Recover a saved Helix edit", false),
                                      ("review.helix.resume", "Resume a Helix workspace", true)] {
            app.registry.register(Command(id: id, title: title, scope: .review,
                budget: .gitWrite, available: { [weak app] _ in
                    guard let app else { return false }
                    let page = ReviewPageState.of(app)
                    return page.helix == nil && !page.scoped && page.integration == nil && page.target != nil
                }, local: { [weak app] _, _ in
                    guard let app else { return }
                    choose(app, resuming: resuming)
                }))
        }
        app.registry.register(Command(id: "review.helix.recover.commit", title: "Finish the selected saved Helix edit", scope: .global,
            budget: .gitWrite, needsArg: true, quiet: true, write: { [weak app] id, arg in
                guard let app, let request = arg as? Request, id == request.source.id,
                      request.reader.isCurrent(app), request.workspace.matches(request.source),
                      let operation = request.workspace.operation, let sha = request.workspace.sha else { return nil }
                let source = request.source, workspace = request.workspace
                guard [workspace.expectedTip, sha].contains(source.tip) else { throw Refusal("the branch moved · the saved edit is preserved") }
                var write = Write(path: app.transport.atRepo(source.repo, "/edit-recover"),
                    body: ["epoch": .string(source.epoch), "branch": .string(source.name), "session": .string(workspace.session),
                           "operation": .string(operation), "expectedTip": .string(workspace.expectedTip)],
                    settled: { true }, failed: "the saved edit still needs recovery", answered: { ok, body in
                        let current = request.reader.isCurrent(app)
                        guard ok, body["ok"] == true else {
                            if current { app.runner.say(body["err"]?.string ?? "the saved edit still needs recovery") }
                            return
                        }
                        let identity = body["epoch"]?.string == source.epoch && body["session"]?.string == workspace.session
                            && body["operation"]?.string == operation && body["repo"]?.string == source.repo
                            && body["branch"]?.string == source.name && body["expectedTip"]?.string == workspace.expectedTip
                            && body["baseSha"]?.string == workspace.baseSha && body["sha"]?.string == sha
                        let nothing = identity && body["nothing"] == true && sha == workspace.expectedTip
                        let receipt = try? JSONValue.object(body).decode(EditReceipt.self)
                        let applied = identity && receipt?.apply(app, source: source, lease: workspace.session, operation: operation,
                            expectedTip: workspace.expectedTip, baseSha: workspace.baseSha, wrote: body["wrote"]?.int ?? 0) == true
                        if current { app.runner.say(nothing || applied ? "recovered the saved Helix edit" : "couldn't verify recovery · the saved edit is preserved") }
                    }, silent: true)
                write.refuseBeforeSend = { [weak app] in
                    guard let app, app.store.epoch == source.epoch else { return "the server changed · reopen saved edits to retry" }
                    guard app.store.view(Branch.self, source.id)?.tip == source.tip else { return "the branch moved · the saved edit is preserved" }
                    guard ReviewPageState.of(app).helix == nil else { return "finish the open editor before recovering a saved edit" }
                    return nil
                }
                return write
            }))
    }

    static func choose(_ app: AppModel, resuming: Bool = false) {
        let page = ReviewPageState.of(app)
        guard let source = BranchSource.current(app, page.id),
              let command = app.registry.command(resuming ? "review.helix.land" : "review.helix.recover.commit"),
              app.runner.refusal?(command) == nil else { return }
        page.editorRecoveryIntent &+= 1
        let intent = page.editorRecoveryIntent, reader = ReaderContext(app)
        page.editorRecoveryTask = Task { @MainActor [weak app, weak page] in
            guard let app, let page else { return }
            let answer = await app.transport.ask(app.transport.atRepo(source.repo, "/edit-workspaces"),
                ["epoch": source.epoch, "branch": source.name], as: Catalog.self)
            guard page.editorRecoveryIntent == intent, reader.isCurrent(app), app.store.epoch == source.epoch,
                  BranchSource.current(app, source.id)?.sameBranch(as: source) == true else { return }
            guard let answer, answer.ok, answer.epoch == source.epoch else { return app.runner.say("couldn't read saved Helix edits") }
            let workspaces = answer.workspaces.filter { resuming ? $0.canResume(source, base: page.baseSha) : $0.matches(source) }
            guard !workspaces.isEmpty else { return app.runner.say(resuming ? "no idle Helix workspaces to resume" : "no saved Helix commits to recover") }
            var picker: ReaderContext?
            app.nav.pick(resuming ? "Helix workspaces" : "saved Helix edits", workspaces.map {
                PickItem(label: resuming ? ($0.entry?.path ?? "workspace") : ($0.message ?? "saved edit"),
                         text: resuming ? "saved editor files on \(source.name)" : "\($0.expectedTip.prefix(8)) → \(($0.sha ?? "").prefix(8))")
            }) { [weak app, weak page] index in
                MainActor.assumeIsolated {
                    guard let app, let page, page.editorRecoveryIntent == intent, picker?.isCurrentAfterPickerChoice(app) == true,
                          workspaces.indices.contains(index), app.store.epoch == source.epoch,
                          BranchSource.current(app, source.id)?.sameBranch(as: source) == true else { return }
                    if resuming {
                        let workspace = workspaces[index]
                        guard workspace.canResume(source, base: page.baseSha), let entry = workspace.entry else { return }
                        page.openHelix(app, branch: source.name, path: entry.path, line: entry.line, col: entry.col, whole: true, workspace: workspace.session)
                        return
                    }
                    app.runner.dispatch("review.helix.recover.commit", via: .key, target: source.id,
                        arg: Request(workspace: workspaces[index], source: source, reader: ReaderContext(app)))
                }
            }
            picker = ReaderContext(app)
        }
    }
}
