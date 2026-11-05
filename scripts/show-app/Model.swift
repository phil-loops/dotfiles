import AppKit

struct Deck: Decodable {
    let title: String
    let subtitle: String?
    let replyTo: String?
    let mode: String?
    /// Read by routing (`App.route`) before the deck is decoded; named here so the deck's keys are all in one place.
    let workspace: String?
    let kind: String?
    let status: LiveStatus?
    let project: String?
    let repo: String?
    let runDir: String?
    /// A live deck: seconds without a file change before the header calls the run stale (default 30); show-job writes 600.
    let staleAfter: Double?
    let repoPath: String?
    let plan: Plan?
    let sections: [Section]

    /// A live deck is watched, not judged: no sign-off bar, no sign-off file, no sign-off marks.
    var isLive: Bool { mode == "live" }
    var isForest: Bool { mode == "forest" }
    /// The Inbox: messages, not a review, so no sign-off checkbox, Send or Submit, only a reply field.
    var isInbox: Bool { mode == "inbox" }
    var isPlan: Bool { plan != nil }
}

struct Section: Decodable {
    let id: String?
    @MissingIsEmpty var group: String
    let title: String
    let tag: String?
    let body: String?
    let url: String?
    /// "plan": the section shows the deck's plan grid instead of a body.
    let view: String?
    let rank: Int?
    let parent: String?
    let status: String?
    let compare: Compare?
    let tables: [DataTable]?
    let source: SourceText?
    let sha: String?
    /// The session this section came from, overriding the deck's `replyTo` (the Inbox holds notes from many sessions).
    let replyTo: String?

    var key: String { id ?? title }
    static let views: Set<String> = ["plan"]
}

struct SignOff: Codable {
    var signed: Bool
    var note: String
    var at: String
}


func loadDeck(_ path: String) throws -> Deck {
    try JSONDecoder().decode(Deck.self, from: expandPlan(Data(contentsOf: URL(fileURLWithPath: path))))
}

/// The parts of a deck file this build doesn't know, like `sections[2].chart` or `view "board"`: a deck written for a
/// newer Show. A key is known when a decoded type has a stored property of that name; a view when it's in `Section.views`.
func unknownParts(ofDeckAt path: String) -> [String] {
    guard let data = try? expandPlan(Data(contentsOf: URL(fileURLWithPath: path))),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let deck = try? JSONDecoder().decode(Deck.self, from: data) else { return [] }
    var parts = unknownKeys(json, in: deck, at: "")
    for view in Set(deck.sections.compactMap(\.view)).subtracting(Section.views).sorted() {
        parts.append("view \"\(view)\"")
    }
    return parts
}

private func unknownKeys(_ json: Any, in value: Any, at path: String) -> [String] {
    var mirror = Mirror(reflecting: value)
    if mirror.displayStyle == .optional {
        guard let wrapped = mirror.children.first?.value else { return [] }
        mirror = Mirror(reflecting: wrapped)
    }
    if let object = json as? [String: Any], mirror.displayStyle == .struct {
        let fields = Dictionary(mirror.children.compactMap { child in child.label.map { (String($0.trimmingPrefix("_")), child.value) } },
                                uniquingKeysWith: { first, _ in first })
        return object.keys.sorted().flatMap { key -> [String] in
            let here = path.isEmpty ? key : "\(path).\(key)"
            guard let field = fields[key] else { return [here] }
            return unknownKeys(object[key]!, in: field, at: here)
        }
    }
    if let array = json as? [Any], mirror.displayStyle == .collection {
        return zip(array, mirror.children).enumerated().flatMap { i, pair in unknownKeys(pair.0, in: pair.1.value, at: "\(path)[\(i)]") }
    }
    return []
}

func modificationDate(_ path: String) -> Date? {
    (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
}
