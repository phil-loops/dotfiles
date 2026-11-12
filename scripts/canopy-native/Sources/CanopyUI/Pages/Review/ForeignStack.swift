import CanopyCore
import Foundation

/// A teammate's PR stack, derived on the server from GitHub's base → head chains (GET /foreign-stack,
/// foreign forests slice 2). A review/pr-N page walks it with J / K: read-only, the one verb a foreign
/// node carries besides reading is preview.
struct ForeignNode: Decodable, Equatable {
    var number: Int
    var title: String
    var head: String
    var base: String
    var parent: Int?
    var depth: Int
    var author: String
    var draft: Bool
    var url: String
}

struct ForeignStackReply: Decodable {
    var ok: Bool
    var root: Int?
    var nodes: [ForeignNode]?
    var err: String?
}

@MainActor
final class ForeignStacks {
    private var byNumber: [Int: (at: Date, nodes: [ForeignNode])] = [:]
    static let fresh: TimeInterval = 60

    static func of(_ app: AppModel) -> ForeignStacks { app.state { ForeignStacks() } }

    /// The PR a review page is on, when it's a teammate's PR imported as review/pr-<N>.
    nonisolated static func prNumber(_ branch: String?) -> Int? {
        guard let b = branch, b.hasPrefix("review/pr-") else { return nil }
        return Int(b.dropFirst("review/pr-".count))
    }

    /// The stack that holds PR `n`, read once a minute at most; nil with the server's reason.
    func load(_ app: AppModel, repo: String, _ n: Int) async -> (nodes: [ForeignNode]?, err: String?) {
        if let hit = byNumber[n], Date().timeIntervalSince(hit.at) < Self.fresh { return (hit.nodes, nil) }
        let path = app.transport.atRepo(repo, "/foreign-stack?number=\(n)")
        guard let r = try? await app.transport.getJSON(path, as: ForeignStackReply.self) else { return (nil, "the server didn't answer") }
        guard r.ok, let nodes = r.nodes else { return (nil, r.err ?? "no stack for #\(n)") }
        for node in nodes { byNumber[node.number] = (Date(), nodes) }
        return (nodes, nil)
    }

    /// The node `d` steps from `n` in stack order (depth first, as the server orders it).
    nonisolated static func step(_ nodes: [ForeignNode], from n: Int, _ d: Int) -> ForeignNode? {
        guard let i = nodes.firstIndex(where: { $0.number == n }), nodes.indices.contains(i + d) else { return nil }
        return nodes[i + d]
    }
}
