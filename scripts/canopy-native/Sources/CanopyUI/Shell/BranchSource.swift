import CanopyCore

struct BranchSource: Hashable {
    let repo: String
    let name: String
    let tip: String
    let parent: String
    let upstream: String
    let pushed: String
    let ahead: Int
    let epoch: String
    let git: Int?
    let remote: Int?
    let hydration: Int
    var id: String { "\(repo):\(name)" }

    @MainActor static func current(_ app: AppModel, _ id: String) -> BranchSource? {
        guard let branch = app.store.view(Branch.self, id) else { return nil }
        return BranchSource(repo: branch.repo, name: branch.name, tip: branch.tip, parent: branch.parent,
                            upstream: branch.upstream, pushed: branch.pushed.rawValue, ahead: branch.ahead,
                            epoch: app.store.epoch, git: app.store.versions[Domain.git], remote: app.store.versions[Domain.remote],
                            hydration: app.store.hydrations)
    }
}
