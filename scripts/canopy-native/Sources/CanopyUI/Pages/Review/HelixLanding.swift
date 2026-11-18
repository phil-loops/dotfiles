import CanopyCore
import Foundation

@MainActor
struct HelixLanding {
    let open: HelixOpen
    let dir: String
    let reader: ReaderContext?

    func presents(_ app: AppModel) -> Bool {
        let page = ReviewPageState.of(app)
        return page.helixSession == open.session && page.id == open.source.id && app.store.epoch == open.source.epoch && reader?.isCurrent(app) == true
    }

    nonisolated static func fullObject(_ sha: String) -> Bool {
        (sha.utf8.count == 40 || sha.utf8.count == 64) && sha.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static func install(_ app: AppModel) {
        app.registry.register(Command(id: "review.helix.land", title: "Commit an editor session on its original branch", scope: .global,
            budget: .gitWrite, needsArg: true, quiet: true, write: { [weak app] id, arg in
                guard let app, let landing = arg as? HelixLanding, id == landing.open.source.id else { return nil }
                let page = ReviewPageState.of(app)
                guard page.helixLandingPermits.remove(landing.open.session) != nil else { return nil }
                let source = landing.open.source
                guard app.store.epoch == source.epoch, let lease = landing.open.lease else { return nil }
                var write = Write(path: app.transport.atRepo(source.repo, "/edit-commit"),
                    body: ["branch": .string(source.name), "session": .string(lease), "expectedTip": .string(source.tip),
                           "operation": .string(landing.open.session.uuidString.lowercased()), "epoch": .string(source.epoch)],
                    settled: { true }, failed: "the edit didn't commit · saved in \(landing.dir)",
                    answered: { ok, body in
                        landing.open.log(ok ? "commit answered" : "commit refused or failed")
                        let speaks = landing.presents(app)
                        let page = ReviewPageState.of(app)
                        let unchanged = ok && body["ok"] == true && body["nothing"] == true && body["epoch"]?.string == source.epoch
                            && body["session"]?.string == lease && body["operation"]?.string == landing.open.session.uuidString.lowercased()
                        let receipt = try? JSONValue.object(body).decode(EditReceipt.self)
                        let commit = ok && body["ok"] == true && !unchanged && receipt?.apply(app, open: landing.open, wrote: body["wrote"]?.int ?? 0) == true
                            ? receipt?.sha : nil
                        if var pending = page.pendingHelixReturn, pending.session == landing.open.session {
                            if let commit {
                                pending.commit = commit
                                page.pendingHelixReturn = pending
                                page.takeHelixReturn(app)
                            } else { page.pendingHelixReturn = nil }
                        }
                        guard speaks else { return }
                        guard ok else {
                            return app.runner.say("\(body["err"]?.string ?? body["error"]?.string ?? "the edit didn't commit") · saved in \(landing.dir)")
                        }
                        guard unchanged || commit != nil else {
                            return app.runner.say("couldn't verify the edit · saved in \(landing.dir)")
                        }
                        app.runner.say(unchanged ? "nothing changed" : "committed “\(body["message"]?.string ?? "the edit")” to \(source.repo)/\(source.name)")
                    }, silent: true)
                write.refuseBeforeSend = { [weak app] in
                    guard let app, app.store.epoch == source.epoch else { return "the server changed · edits are saved in \(landing.dir)" }
                    guard app.store.view(Branch.self, source.id)?.tip == source.tip else { return "the branch changed · edits are saved in \(landing.dir)" }
                    return nil
                }
                return write
            }))
    }
}
