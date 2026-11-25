import CanopyCore
import Foundation
import Observation

/// What changed in a forest since Phil's last spoken review, as the session that answered it wrote it
/// (`show-review-reply` → `~/.cache/show/reviews/<stamp>-<forest>/since.json`).
struct ReviewSince: Decodable, Equatable, Sendable {
    struct Answer: Decodable, Equatable, Sendable {
        var id: String
        var state: String
        var commits: String?
        var text: String
    }

    struct Note: Decodable, Equatable, Sendable {
        var id: String
        var file: String?
        var line: Int?
        var said: String?
        var answers: [Answer]
    }

    struct Entry: Decodable, Equatable, Sendable {
        var kind: String
        var tipThen: String?
        var tipNow: String?
        var why: String?
        var changed: [String]?
        var added: [String]?
        var dropped: [String]?
        var notes: [Note]?
        var needsEyes: [Answer]?
    }

    var forest: String
    var branches: [String: Entry]

    /// How a branch stands against the review, its tip compared with the one the answer was written for.
    enum Mark: Equatable {
        case same, asked, unasked, new, eyes
        /// the tip moved after the answer was written: what it says is about an older tip
        case moved

        var word: String? {
            switch self {
            case .same: nil
            case .asked: "changed as asked"
            case .unasked: "changed unasked"
            case .new: "new"
            case .eyes: "needs your eyes"
            case .moved: "moved since the summary"
            }
        }

        /// whether it asks to be read before the rest
        var loud: Bool { self == .eyes || self == .unasked || self == .new }
    }

    /// The branch's entry, only while its tip is the one the answer was written for; nil when the review didn't name it.
    func trusted(_ branch: String, tip: String) -> Entry? {
        guard let e = branches[branch], e.tipNow == tip else { return nil }
        return e
    }

    func mark(_ branch: String, tip: String) -> Mark? {
        guard let e = branches[branch] else { return nil }
        guard e.tipNow == tip else { return .moved }
        if !(e.needsEyes ?? []).isEmpty { return .eyes }
        switch e.kind {
        case "same": return .same
        case "asked": return .asked
        case "unasked": return .unasked
        case "new": return .new
        default: return nil
        }
    }

    /// The one line under the branch: what still wants Phil; else, changed as he asked, what was done (the answers);
    /// else the answering session's why.
    static func line(_ e: Entry) -> String? {
        if let a = e.needsEyes?.first { return "\(a.state): \(a.text)" }
        if e.kind == "asked", let first = answers(e).first { return first.answer.text }
        return e.why.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Everything the line stands for, for its hover: every answer, else the why.
    static func detail(_ e: Entry) -> String {
        let all = answers(e).map { "\($0.answer.state): \($0.answer.text)" }
        return all.isEmpty ? (e.why ?? "") : all.joined(separator: "\n")
    }

    /// The files it touched since the review: changed or added (dropped ones aren't in the diff).
    static func touched(_ e: Entry) -> Set<String> { Set((e.changed ?? []) + (e.added ?? [])) }

    /// Answers worth showing beside their note: everything but a note that asked nothing.
    static func answers(_ e: Entry) -> [(note: Note, answer: Answer)] {
        (e.notes ?? []).flatMap { n in n.answers.filter { $0.state != "no ask" }.map { (n, $0) } }
    }

    /// An answer whose state means Phil still has to look (partly, declined, won't, ask).
    static func needsEyes(_ a: Answer, in e: Entry) -> Bool { (e.needsEyes ?? []).contains { $0.id == a.id } }
}

/// Reads the newest review of a forest that has an answer, from the reviews folder.
struct ReviewSinceIO: Sendable {
    var dir: URL

    static var local: ReviewSinceIO {
        let path = ProcessInfo.processInfo.environment["SHOW_REVIEWS"] ?? "~/.cache/show/reviews"
        return ReviewSinceIO(dir: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
    }

    private struct Review: Decodable { var repo: String? }

    /// The newest `<stamp>-<forest>` folder whose since.json names this forest and whose review.json this repo.
    func latest(repo: String, forest: String) -> ReviewSince? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        for name in names.filter({ $0.hasSuffix("-\(forest)") }).sorted(by: >) {
            let folder = dir.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("since.json")),
                  let since = try? JSONDecoder().decode(ReviewSince.self, from: data), since.forest == forest,
                  let review = (try? Data(contentsOf: folder.appendingPathComponent("review.json"))).flatMap({ try? JSONDecoder().decode(Review.self, from: $0) }),
                  review.repo == repo else { continue }
            return since
        }
        return nil
    }
}

/// The latest answered review per forest, read when a page asks and again whenever a since.json is written.
@MainActor @Observable
final class ReviewSinceStore {
    static func of(_ app: AppModel) -> ReviewSinceStore { app.state { ReviewSinceStore() } }

    @ObservationIgnored var io = ReviewSinceIO.local
    private(set) var byForest: [String: ReviewSince] = [:]
    @ObservationIgnored private var asked: Set<String> = []
    @ObservationIgnored private var watch: RecordWatch?

    private static func key(_ repo: String, _ forest: String) -> String { "\(repo)\t\(forest)" }

    func since(repo: String, forest: String) -> ReviewSince? { byForest[Self.key(repo, forest)] }

    /// Reads this forest's review now, and keeps it current from then on.
    func load(repo: String, forest: String) async {
        asked.insert(Self.key(repo, forest))
        if watch == nil {
            try? FileManager.default.createDirectory(at: io.dir, withIntermediateDirectories: true)
            watch = RecordWatch(dir: io.dir.path, wanted: { $0 == "since.json" }) { [weak self] in
                guard let self else { return }
                Task { await self.reload() }
            }
        }
        let io = io
        let got = await Task.detached { io.latest(repo: repo, forest: forest) }.value
        if byForest[Self.key(repo, forest)] != got { byForest[Self.key(repo, forest)] = got }
    }

    private func reload() async {
        for key in asked {
            let parts = key.components(separatedBy: "\t")
            await load(repo: parts[0], forest: parts[1])
        }
    }
}
