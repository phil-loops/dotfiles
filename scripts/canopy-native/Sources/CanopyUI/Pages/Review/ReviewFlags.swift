import CanopyCore
import Foundation

/// One finding push-ready's review left on a branch's tree (GET /review-flags): where, and what.
public struct ReviewFlag: Decodable, Equatable, Sendable {
    public var path: String?
    public var line: Int?
    public var text: String
}

/// The review page's findings, read once per branch tip once a review has run on it. "No review
/// yet" is asked again each time, since a review can land on a tip after the first look.
@MainActor
final class ReviewFlags {
    struct Source: Hashable {
        let id: String
        let tip: String
        let generation: Int
    }

    private struct Reply: Decodable {
        let flags: [ReviewFlag]?
        private enum CodingKeys: String, CodingKey { case flags }
        init(from decoder: Decoder) throws {
            flags = try decoder.container(keyedBy: CodingKeys.self).decode([ReviewFlag]?.self, forKey: .flags)
        }
    }
    private var cache: [Source: [ReviewFlag]] = [:]
    private var tracked: [String: Source] = [:]
    private weak var app: AppModel?

    private init(_ app: AppModel) {
        self.app = app
        _ = app.store.onChange { [weak self] in self?.refresh() }
    }

    static func of(_ app: AppModel) -> ReviewFlags { app.state { ReviewFlags(app) } }

    func source(_ id: String) -> Source {
        // the flags are recorded in the branch's config by a review run: the readStamp moves with them
        let b = app?.store.view(Branch.self, id)
        let tip = b.map { "\($0.tip)|\($0.readStamp ?? "")" } ?? app?.store.view(Conv.self, id)?.tip ?? ""
        if let source = tracked[id], source.tip == tip { return source }
        let source = Source(id: id, tip: tip, generation: (tracked[id]?.generation ?? 0) + 1)
        tracked[id] = source
        cache = cache.filter { $0.key.id != id }
        return source
    }

    private func refresh() { for id in Array(tracked.keys) { _ = source(id) } }

    /// The findings for the branch's current source when a read already has them.
    func cached(_ app: AppModel, _ target: ReviewPageState.Target) -> [ReviewFlag]? { cache[source(target.id)] }

    /// A missing review is asked again; a response cannot cross a source change, including leaving and returning to a tip.
    func load(_ app: AppModel, _ target: ReviewPageState.Target) async throws -> [ReviewFlag]? {
        let origin = source(target.id)
        if let got = cache[origin] { return got }
        let path = app.transport.atRepo(target.repo, "/review-flags?branch=\(target.name.uriComponent)")
        let got = try await app.transport.getJSON(path, as: Reply.self).flags
        guard source(target.id) == origin else { return nil }
        if let got { cache[origin] = got }
        return got
    }
}
