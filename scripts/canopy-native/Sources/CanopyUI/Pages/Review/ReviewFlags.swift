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
    private struct Reply: Decodable { var flags: [ReviewFlag]? }
    private var cache: [String: [ReviewFlag]] = [:]

    static func of(_ app: AppModel) -> ReviewFlags { app.state { ReviewFlags() } }

    /// nil when no review is recorded for the tree the branch has now.
    func load(_ app: AppModel, _ t: ReviewPageState.Target) async -> [ReviewFlag]? {
        let tip = app.store.view(Branch.self, t.id)?.tip ?? ""
        let key = "\(t.id)@\(tip)"
        if let got = cache[key] { return got }
        let path = app.transport.atRepo(t.repo, "/review-flags?branch=\(t.name.uriComponent)")
        let got = (try? await app.transport.getJSON(path, as: Reply.self))?.flags
        if let got { cache[key] = got }
        return got
    }
}
