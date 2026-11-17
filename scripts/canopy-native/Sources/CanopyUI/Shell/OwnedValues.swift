import Observation

@MainActor
@Observable
final class OwnedValues<Key: Hashable, Value> {
    struct Change {
        let key: Key
        let value: Value?
    }

    fileprivate final class Identity {}

    struct Receipt {
        fileprivate let owner: Identity
        fileprivate let nodes: [Key: Node]
    }

    struct Snapshot {
        fileprivate struct Entry { let revision: Identity; let pending: Bool }
        fileprivate let owner: Identity
        fileprivate let entries: [Key: Entry]
    }

    @MainActor fileprivate final class Node {
        enum State { case pending, accepted, failed }
        var value: Value?
        var before: Value?
        var previous: Node?
        var state = State.pending

        init(value: Value?, before: Value?, previous: Node?) {
            self.value = value
            self.before = before
            self.previous = previous
        }
    }

    private(set) var values: [Key: Value] = [:]
    @ObservationIgnored private let identity = Identity()
    @ObservationIgnored private var revisions: [Key: Identity] = [:]
    @ObservationIgnored private var owners: [Key: Node] = [:]

    func isPending(_ key: Key) -> Bool { owners[key] != nil }

    func set(_ key: Key, _ value: Value?) {
        put(key, value)
        owners[key] = nil
    }

    func stage(_ changes: [Change]) -> Receipt {
        precondition(Set(changes.map(\.key)).count == changes.count)
        var nodes: [Key: Node] = [:]
        for change in changes {
            let node = Node(value: change.value, before: values[change.key], previous: owners[change.key])
            nodes[change.key] = node
            owners[change.key] = node
            put(change.key, change.value)
        }
        return Receipt(owner: identity, nodes: nodes)
    }

    func before(_ receipt: Receipt, _ key: Key) -> Value? {
        guard receipt.owner === identity else { return nil }
        guard let node = receipt.nodes[key] else { return nil }
        let prior = predecessor(node)
        if prior.node?.state != .pending {
            node.before = prior.value
            node.previous = nil
        }
        return prior.value
    }

    func rollback(_ receipt: Receipt, keys: Set<Key>? = nil) {
        guard receipt.owner === identity else { return }
        for (key, node) in receipt.nodes where keys?.contains(key) != false && node.state == .pending {
            node.state = .failed
            guard owners[key] === node else { continue }
            let prior = predecessor(node)
            put(key, prior.value)
            owners[key] = prior.node?.state == .pending ? prior.node : nil
        }
    }

    func accept(_ receipt: Receipt, keys: Set<Key>? = nil, replacing changes: [Change] = []) {
        guard receipt.owner === identity else { return }
        let replacements = Dictionary(uniqueKeysWithValues: changes.map { ($0.key, $0) })
        for (key, node) in receipt.nodes where keys?.contains(key) != false && node.state == .pending {
            if let change = replacements[key] {
                node.value = change.value
                if owners[key] === node { put(key, change.value) }
            }
            node.state = .accepted
            let prior = predecessor(node)
            if prior.node?.state != .pending {
                node.before = prior.value
                node.previous = nil
            }
            if owners[key] === node { owners[key] = nil }
        }
    }

    func snapshot() -> Snapshot {
        Snapshot(owner: identity, entries: Dictionary(uniqueKeysWithValues: revisions.map { key, revision in
            (key, Snapshot.Entry(revision: revision, pending: owners[key] != nil))
        }))
    }

    func discardUnchanged(_ snapshot: Snapshot, keys: Set<Key>? = nil) {
        guard snapshot.owner === identity else { return }
        for (key, entry) in snapshot.entries where keys?.contains(key) != false && !entry.pending && owners[key] == nil && revisions[key] === entry.revision {
            set(key, nil)
        }
    }

    private func put(_ key: Key, _ value: Value?) {
        values[key] = value
        revisions[key] = value == nil ? nil : Identity()
    }

    private func predecessor(_ node: Node) -> (value: Value?, node: Node?) {
        var value = node.before
        var previous = node.previous
        while let prior = previous {
            if prior.state != .failed { return (prior.value, prior) }
            value = prior.before
            previous = prior.previous
        }
        return (value, nil)
    }
}
