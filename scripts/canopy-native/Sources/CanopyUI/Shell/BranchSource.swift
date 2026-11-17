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
    /// the parent's tip, set only on a history key (`forHistory`): what `/commits` reads in place
    /// of the repo-wide versions
    var parentTip = ""
    var id: String { "\(repo):\(name)" }

    /// The key for what a branch's history (`/commits`) reads: this branch's tip, upstream and push
    /// state, and its parent's tip (which commits are its own). Not the repo-wide git/remote
    /// versions: those bump on every other branch's commit, and with agents committing across the
    /// repo each bump cancelled the read in flight, so a slow read never landed and the page sat at
    /// "reading the commits…" (2026-11-17).
    func forHistory(parentTip: String) -> BranchSource {
        var s = BranchSource(repo: repo, name: name, tip: tip, parent: parent, upstream: upstream, pushed: pushed,
                             ahead: ahead, epoch: epoch, git: nil, remote: nil, hydration: hydration)
        s.parentTip = parentTip
        return s
    }

    @MainActor static func history(_ app: AppModel, _ id: String) -> BranchSource? {
        guard let s = current(app, id) else { return nil }
        return s.forHistory(parentTip: app.store.view(Branch.self, "\(s.repo):\(s.parent)")?.tip ?? "")
    }

    @MainActor static func current(_ app: AppModel, _ id: String) -> BranchSource? {
        guard let branch = app.store.view(Branch.self, id) else { return nil }
        return BranchSource(repo: branch.repo, name: branch.name, tip: branch.tip, parent: branch.parent,
                            upstream: branch.upstream, pushed: branch.pushed.rawValue, ahead: branch.ahead,
                            epoch: app.store.epoch, git: app.store.versions[Domain.git], remote: app.store.versions[Domain.remote],
                            hydration: app.store.hydrations)
    }
}
