import CanopyCore
import Foundation

// The Ship area's response types (API.md §3, §4, §6). Every field the server may leave out decodes
// to a default, so a new or missing key never drops the whole answer.

private extension KeyedDecodingContainer {
    func or<T: Decodable>(_ k: Key, _ d: T) -> T { (try? decodeIfPresent(T.self, forKey: k)) ?? d }
}

/// One commit as GET /outline tells it (srv/outline.py): its whole message, whether a remote holds
/// it, and why it can't be reworded here.
public struct OutlineCommit: Decodable, Equatable, Sendable {
    public var sha: String
    public var short: String
    public var subject: String
    public var body: String
    public var author: String
    public var date: String
    public var pushed: Bool
    public var carried: Bool
    /// why it can't be reworded here (on a remote, a merge, carried from a dep), else ""
    public var locked: String

    public init(sha: String, short: String? = nil, subject: String, body: String = "", author: String = "", date: String = "",
                pushed: Bool = false, carried: Bool = false, locked: String = "") {
        self.sha = sha; self.short = short ?? String(sha.prefix(7)); self.subject = subject; self.body = body; self.author = author
        self.date = date; self.pushed = pushed; self.carried = carried; self.locked = locked
    }

    enum K: String, CodingKey { case sha, short, subject, body, author, date, pushed, carried, locked }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        sha = try c.decode(String.self, forKey: .sha)
        short = c.or(.short, String(sha.prefix(7)))
        subject = c.or(.subject, ""); body = c.or(.body, ""); author = c.or(.author, ""); date = c.or(.date, "")
        pushed = c.or(.pushed, false); carried = c.or(.carried, false)
        // the server sends a reason string, or false/"" when it's free to reword
        locked = (try? c.decodeIfPresent(String.self, forKey: .locked)) ?? ""
    }
}

/// GET /outline.
public struct WordsOutline: Decodable, Equatable, Sendable {
    public struct Landing: Decodable, Equatable, Sendable {
        public var title: String
        public var body: String
        public var titleSaved: Bool
        public var bodySaved: Bool
        public var bodyPending: Bool
        public init(title: String, body: String, titleSaved: Bool = false, bodySaved: Bool = false, bodyPending: Bool = false) {
            self.title = title; self.body = body; self.titleSaved = titleSaved; self.bodySaved = bodySaved; self.bodyPending = bodyPending
        }
        enum K: String, CodingKey { case title, body, titleSaved, bodySaved, bodyPending }
        public init(from d: Decoder) throws {
            let c = try d.container(keyedBy: K.self)
            title = c.or(.title, ""); body = c.or(.body, ""); titleSaved = c.or(.titleSaved, false)
            bodySaved = c.or(.bodySaved, false); bodyPending = c.or(.bodyPending, false)
        }
    }

    /// An open PR's own text lives on GitHub; the draft no longer applies.
    public struct PR: Decodable, Equatable, Sendable {
        public var exists: Bool
        public var number: Int?
        public var url: String?
        public var state: String?
        public var title: String?
        public var body: String?
        public init(exists: Bool, number: Int? = nil, url: String? = nil, state: String? = nil, title: String? = nil, body: String? = nil) {
            self.exists = exists; self.number = number; self.url = url; self.state = state; self.title = title; self.body = body
        }
        enum K: String, CodingKey { case exists, number, url, state, title, body }
        public init(from d: Decoder) throws {
            let c = try d.container(keyedBy: K.self)
            exists = c.or(.exists, false); number = try? c.decodeIfPresent(Int.self, forKey: .number)
            url = try? c.decodeIfPresent(String.self, forKey: .url); state = try? c.decodeIfPresent(String.self, forKey: .state)
            title = try? c.decodeIfPresent(String.self, forKey: .title); body = try? c.decodeIfPresent(String.self, forKey: .body)
        }
    }

    public var branch: String
    public var head: String
    public var description: String
    public var ticket: String?
    public var commits: [OutlineCommit]
    /// the landing text: what the PR opens with (drafted until Phil saves his own)
    public var draft: Landing?
    public var pr: PR?

    public init(branch: String, head: String, description: String = "", ticket: String? = nil, commits: [OutlineCommit], draft: Landing? = nil, pr: PR? = nil) {
        self.branch = branch; self.head = head; self.description = description; self.ticket = ticket; self.commits = commits; self.draft = draft; self.pr = pr
    }

    enum K: String, CodingKey { case branch, head, description, ticket, commits, draft, pr }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        branch = c.or(.branch, ""); head = c.or(.head, ""); description = c.or(.description, "")
        ticket = try? c.decodeIfPresent(String.self, forKey: .ticket)
        commits = c.or(.commits, [])
        draft = try? c.decodeIfPresent(Landing.self, forKey: .draft)
        pr = try? c.decodeIfPresent(PR.self, forKey: .pr)
    }
}

/// One of the branch's commits in the history list (GET /commits).
public struct HistoryCommit: Decodable, Equatable, Sendable {
    public var sha: String
    public var subject: String
    public var body: String
    public var author: String
    public var date: String
    public var own: Bool
    public var pushed: Bool?

    public init(sha: String, subject: String, body: String = "", author: String = "", date: String = "", own: Bool = true, pushed: Bool? = nil) {
        self.sha = sha; self.subject = subject; self.body = body; self.author = author; self.date = date; self.own = own; self.pushed = pushed
    }
    enum K: String, CodingKey { case sha, subject, body, author, date, own, pushed }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        sha = try c.decode(String.self, forKey: .sha)
        subject = c.or(.subject, ""); body = c.or(.body, ""); author = c.or(.author, ""); date = c.or(.date, "")
        own = c.or(.own, false); pushed = try? c.decodeIfPresent(Bool.self, forKey: .pushed)
    }
}

/// GET /force-scope `forceScope` (srv/sync.py force_scope): no PR, or a draft no one else has
/// touched, and gates green on this tree. /force-origin checks it all again; this only says.
public struct ForceScope: Decodable, Equatable, Sendable {
    public struct Guard: Decodable, Equatable, Sendable {
        public var k: String
        public var label: String
        public var ok: Bool
    }
    public var eligible: Bool
    public var guards: [Guard]
    public var lease: String
    public var prNumber: Int?
    public var prUrl: String?
}

/// GET /diverged-detail.
public struct DivergedDetail: Decodable, Equatable, Sendable {
    public struct Ahead: Decodable, Equatable, Sendable {
        public var sha: String
        public var subject: String
        public var matched: Bool
        public var fromMain: Bool
        enum K: String, CodingKey { case sha, subject, matched, fromMain }
        public init(from d: Decoder) throws {
            let c = try d.container(keyedBy: K.self)
            sha = c.or(.sha, ""); subject = c.or(.subject, ""); matched = c.or(.matched, false); fromMain = c.or(.fromMain, false)
        }
    }
    public var upstream: String
    public var ahead: [Ahead]
    public var behind: [Ahead]
    public var containment: String
    public var overlap: [String]
    public var prNow: String
    public var prAfter: String

    enum K: String, CodingKey { case upstream, ahead, behind, containment, overlap, prNow, prAfter }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        upstream = c.or(.upstream, ""); ahead = c.or(.ahead, []); behind = c.or(.behind, []); containment = c.or(.containment, "")
        overlap = c.or(.overlap, []); prNow = c.or(.prNow, ""); prAfter = c.or(.prAfter, "")
    }

    public static let containmentWord: [String: String] = [
        "rebase": "a rebase — origin's commits are all here, rewritten",
        "contained": "origin's content is already here",
        "clean-extra": "origin has changes local lacks — they merge cleanly",
        "overlap": "both sides changed the same places",
    ]
}
