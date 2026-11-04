import AppKit

struct Deck: Decodable {
    let title: String
    let subtitle: String?
    let replyTo: String?
    let mode: String?
    let status: LiveStatus?
    let project: String?
    let repo: String?
    let runDir: String?
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
}

struct SignOff: Codable {
    var signed: Bool
    var note: String
    var at: String
}


func loadDeck(_ path: String) throws -> Deck {
    try JSONDecoder().decode(Deck.self, from: expandPlan(Data(contentsOf: URL(fileURLWithPath: path))))
}

func modificationDate(_ path: String) -> Date? {
    (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
}
