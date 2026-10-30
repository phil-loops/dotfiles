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
    let sections: [Section]

    /// A live deck is watched, not judged: no sign-off bar, no sign-off file, no sign-off marks.
    var isLive: Bool { mode == "live" }
    var isForest: Bool { mode == "forest" }
}

struct Section: Decodable {
    let id: String?
    @MissingIsEmpty var group: String
    let title: String
    let tag: String?
    let body: String?
    let url: String?
    let rank: Int?
    let parent: String?
    let status: String?
    let compare: Compare?
    let tables: [DataTable]?
    let source: SourceText?
    let sha: String?

    var key: String { id ?? title }
}

struct SignOff: Codable {
    var signed: Bool
    var note: String
    var at: String
}


func loadDeck(_ path: String) throws -> Deck {
    try JSONDecoder().decode(Deck.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
}

func modificationDate(_ path: String) -> Date? {
    (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
}
