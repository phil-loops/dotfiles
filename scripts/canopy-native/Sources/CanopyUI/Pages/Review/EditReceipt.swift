import CanopyCore
import Foundation

struct EditReceipt: Decodable {
    let epoch: String
    let session: String
    let operation: String
    let repo: String
    let branch: String
    let expectedTip: String
    let sha: String
    let tree: String
    let baseSha: String
    let paths: [String]
    let files: [NodeFile]
    let history: HistoryCommit
    let incremental: Bool?

    @MainActor func apply(_ app: AppModel, open: HelixOpen, wrote: Int) -> Bool {
        apply(app, source: open.source, lease: open.lease ?? "", operation: open.session.uuidString.lowercased(),
              expectedTip: open.source.tip, baseSha: open.editBase ?? "", wrote: wrote)
    }

    @MainActor func apply(_ app: AppModel, source: BranchSource, lease: String, operation: String,
                          expectedTip: String, baseSha: String, wrote: Int) -> Bool {
        guard epoch == source.epoch, app.store.epoch == source.epoch, session == lease, self.operation == operation, repo == source.repo,
              branch == source.name, self.expectedTip == expectedTip, self.baseSha == baseSha,
              HelixLanding.fullObject(sha), sha != expectedTip, HelixLanding.fullObject(tree), history.sha == sha,
              history.own, Set(files.map(\.path)).count == files.count,
              Set(files.map(\.path)).isSubset(of: Set(paths)) else { return false }
        if source.tip == sha { return app.store.view(Branch.self, source.id)?.tip == sha }
        guard source.tip == expectedTip else { return false }
        let page = ReviewPageState.of(app)
        let previous = page.id == source.id && page.tip == expectedTip && page.diffCurrent && page.baseSha == baseSha && !page.scoped
            ? page.payload?.data : nil
        let history = BranchHistory.of(app)
        let rows = history.stamp(source.id) != nil ? history.rows(source.id) : nil
        guard app.store.acceptBranchReceipt(source.id, epoch: source.epoch, expectedTip: expectedTip,
            fields: ["tip": .string(sha), "tree": .string(tree), "gates": "none", "redGates": []], wrote: wrote) else { return false }
        if let rows { history.put(source.id, rows: [self.history] + rows.filter { $0.sha != sha }) }
        if var data = previous, page.tip == sha, incremental != false {
            let changed = Set(paths)
            data.files.removeAll { changed.contains($0.path) }
            data.files.append(contentsOf: files)
            data.files.sort { $0.path < $1.path }
            page.land(page.keyOf, data, preservingFiles: true)
        }
        return true
    }
}
