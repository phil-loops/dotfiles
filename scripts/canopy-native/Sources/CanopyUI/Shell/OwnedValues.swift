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

    @MainActor fileprivate final class Node {
        enum State { case pending, accepted, failed }
        let value: Value?
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
    @ObservationIgnored private var owners: [Key: Node] = [:]

    func set(_ key: Key, _ value: Value?) {
        values[key] = value
        owners[key] = nil
    }

    func stage(_ changes: [Change]) -> Receipt {
        precondition(Set(changes.map(\.key)).count == changes.count)
        var nodes: [Key: Node] = [:]
        for change in changes {
            let node = Node(value: change.value, before: values[change.key], previous: owners[change.key])
            nodes[change.key] = node
            owners[change.key] = node
            values[change.key] = change.value
        }
        return Receipt(owner: identity, nodes: nodes)
    }

    func before(_ receipt: Receipt, _ key: Key) -> Value? {
        guard receipt.owner === identity else { return nil }
        return receipt.nodes[key].flatMap { predecessor($0).value }
    }

    func rollback(_ receipt: Receipt, keys: Set<Key>? = nil) {
        guard receipt.owner === identity else { return }
        for (key, node) in receipt.nodes where keys?.contains(key) != false && node.state == .pending {
            node.state = .failed
            guard owners[key] === node else { continue }
            let prior = predecessor(node)
            values[key] = prior.value
            owners[key] = prior.node?.state == .pending ? prior.node : nil
        }
    }

    func accept(_ receipt: Receipt, keys: Set<Key>? = nil) {
        guard receipt.owner === identity else { return }
        for (key, node) in receipt.nodes where keys?.contains(key) != false && node.state == .pending {
            node.state = .accepted
            let prior = predecessor(node)
            if prior.node?.state != .pending {
                node.before = prior.value
                node.previous = nil
            }
            if owners[key] === node { owners[key] = nil }
        }
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
