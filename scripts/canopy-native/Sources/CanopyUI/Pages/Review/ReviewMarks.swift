import CanopyCore
import Observation

@MainActor
@Observable
final class ReviewMarks {
    struct Receipt {
        let repo: String
        let keys: Set<String>
        let before: [String: Mark]
        let marks: [String: Mark]
        let beforeRevisions: [String: Int]
        let revision: Int
    }

    private struct Key: Hashable {
        let repo: String
        let key: String
    }

    private var byRepo: [String: [String: Mark]] = [:]
    @ObservationIgnored private var revisions: [Key: Int] = [:]
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var receipts: [Int: (receipt: Receipt, accepted: Bool, confirmed: Set<String>)] = [:]
    @ObservationIgnored private var failed: Set<Int> = []
    @ObservationIgnored private weak var app: AppModel?

    private init(_ app: AppModel) {
        self.app = app
        _ = app.store.onChange { [weak self] in self?.reconcile() }
    }

    static func of(_ app: AppModel) -> ReviewMarks { app.state { ReviewMarks(app) } }

    func overrides(_ repo: String) -> [String: Mark] { byRepo[repo] ?? [:] }

    func replace(_ repo: String, with values: [String: Mark]) {
        let old = overrides(repo)
        let changed = Set(old.keys).union(values.keys).filter { old[$0] != values[$0] }
        guard !changed.isEmpty else { return }
        put(repo, values, touching: changed)
        prune()
    }

    func apply(_ repo: String, _ marks: [String: Mark]) -> Receipt {
        let before = overrides(repo)
        let prior = Dictionary(uniqueKeysWithValues: marks.keys.compactMap { key in
            before[key].flatMap { _ in revisions[Key(repo: repo, key: key)].map { (key, $0) } }
        })
        var next = before
        for (key, mark) in marks { next[key] = mark }
        let keys = Set(marks.keys)
        put(repo, next, touching: keys)
        let receipt = Receipt(repo: repo, keys: keys, before: before.filter { keys.contains($0.key) }, marks: marks, beforeRevisions: prior, revision: revision)
        receipts[revision] = (receipt, false, [])
        return receipt
    }

    func rollback(_ receipt: Receipt) {
        failed.insert(receipt.revision)
        let keys = receipt.keys.filter { revisions[Key(repo: receipt.repo, key: $0)] == receipt.revision }
        var next = overrides(receipt.repo)
        for key in keys {
            var value = receipt.before[key]
            var prior = receipt.beforeRevisions[key]
            while let revision = prior, let old = receipts[revision] {
                if old.confirmed.contains(key) { value = nil; prior = nil; break }
                guard failed.contains(revision) else { break }
                value = old.receipt.before[key]
                prior = old.receipt.beforeRevisions[key]
            }
            next[key] = value
            revisions[Key(repo: receipt.repo, key: key)] = prior
        }
        if !keys.isEmpty { byRepo[receipt.repo] = next }
        reconcile()
    }

    func accept(_ receipt: Receipt) {
        if receipts[receipt.revision] != nil {
            receipts[receipt.revision]?.accepted = true
        }
        reconcile()
    }

    private func put(_ repo: String, _ values: [String: Mark], touching keys: Set<String>) {
        revision &+= 1
        for key in keys { revisions[Key(repo: repo, key: key)] = revision }
        byRepo[repo] = values
    }

    func serverMarks(_ repo: String) -> (viewed: Set<String>, flagged: Set<String>) {
        guard let app else { return ([], []) }
        var viewed = Set<String>(), flagged = Set<String>()
        for value in app.store.table(Viewed.self).values where value.repo == repo {
            viewed.formUnion(value.keys)
            flagged.formUnion(value.flagged ?? [])
        }
        return (viewed, flagged)
    }

    func serverMark(_ repo: String, _ key: String) -> Mark {
        let marks = serverMarks(repo)
        return marks.flagged.contains(key) ? .flagged : marks.viewed.contains(key) ? .viewed : .unread
    }

    private func reconcile() {
        for (revision, state) in receipts where state.accepted {
            let marks = serverMarks(state.receipt.repo)
            let confirmed = Set(state.receipt.keys.filter { key in
                let mark: Mark = marks.flagged.contains(key) ? .flagged : marks.viewed.contains(key) ? .viewed : .unread
                return state.receipt.marks[key] == mark
            })
            receipts[revision]?.confirmed.formUnion(confirmed)
        }
        for (repo, values) in byRepo {
            let marks = serverMarks(repo)
            let retired = Set(values.keys.filter { key in
                if let revision = revisions[Key(repo: repo, key: key)], let receipt = receipts[revision] { return receipt.confirmed.contains(key) }
                let mark: Mark = marks.flagged.contains(key) ? .flagged : marks.viewed.contains(key) ? .viewed : .unread
                return values[key] == mark
            })
            if !retired.isEmpty { put(repo, values.filter { !retired.contains($0.key) }, touching: retired) }
        }
        prune()
    }

    private func prune() {
        revisions = revisions.filter { byRepo[$0.key.repo]?[$0.key.key] != nil }
        var live = Set(revisions.values)
        var pending = Array(live)
        while let revision = pending.popLast() {
            guard let receipt = receipts[revision]?.receipt else { continue }
            for prior in receipt.beforeRevisions.values where live.insert(prior).inserted { pending.append(prior) }
        }
        receipts = receipts.filter { live.contains($0.key) }
        failed.formIntersection(live)
    }
}
