import AppKit
import CanopyCore
import Foundation

/// The keytutor's practice world: a whole AppModel on canned data, every request it makes answered
/// by `KeyTutorStub` — so `m`, `⌃↵`, `p`, `X`, sync and the rest never reach git, the live server or
/// GitHub. The fixture is the shape of the real /state (Tests/CanopyCoreTests/Fixtures/state.json),
/// cut down to one practice repo: two focus forests, a stack that forks, a branch with a three-file
/// diff and two open threads, and a short tracker queue.
enum KeyTutorSandbox {
    static let repo = "practice"
    static let greetings = "\(repo):greetings"
    static let farewells = "\(repo):farewells"
    /// The stack, in merge order: add-greeting forks into header and footer; banner sits on header.
    static let root = "add-greeting", header = "use-greeting-in-header", footer = "use-greeting-in-footer"
    static let banner = "wave-in-the-banner", farewell = "add-farewell"
    static func id(_ name: String) -> String { "\(repo):\(name)" }
    static let thread1 = "\(repo):\(root)#T1", thread2 = "\(repo):\(root)#T2"

    nonisolated(unsafe) private static var nextPort = 61_000

    /// A practice app: canned store, stubbed transport, nothing that opens, copies or remembers
    /// outside itself. `keys` lays the host's keys over its verb table.
    @MainActor static func make(overrides: [String: [String]] = [:], shared: [String: [String]] = [:]) -> AppModel {
        nextPort += 1
        let port = nextPort
        KeyTutorStub.open(port)
        var c = AppConfig()
        c.port = port
        c.route = .forests
        let app = AppModel(config: c, port: port, telemetry: false, protocolClasses: [KeyTutorStub.self])
        app.alwaysLive = [.practice]
        app.transport.repos = [repo]
        app.store.hydrate(try! Snapshot.decode(JSONEncoder().encode(snapshot())))
        app.registry.applyUserKeys(overrides, shared: shared)

        // nothing leaves: no browser, no clipboard, no remembered prefs, no Socratic sessions
        let ship = ShipState.of(app)
        ship.openURL = { u in KeyTutorStub.note(port, "open \(u.absoluteString)") }
        ship.copyText = { s in KeyTutorStub.note(port, "copy \(s)") }
        ship.defaults = MemoryDefaults()
        let fm = app.forestModel
        fm.defaults = MemoryDefaults()
        fm.face = .branches
        app.state { Workstation(app: app) }.openURL = { u in KeyTutorStub.note(port, "open \(u.absoluteString)") }
        let tutor = TutorArea.state(app)
        tutor.sessionsFile = nil
        tutor.sessions = []
        return app
    }

    // ── the canned /state ──

    static let trunk = String(repeating: "0", count: 40)
    static func tip(_ name: String) -> String {
        [root: "a1", header: "b2", footer: "c3", banner: "d4", farewell: "e5"][name, default: "f6"].padding(toLength: 40, withPad: "0", startingAt: 0)
    }

    static func branch(_ name: String, project: String, parent: String?, order: Int, description: String, subject: String) -> JSONValue {
        [
            "id": .string(id(name)), "repo": .string(repo), "name": .string(name), "project": .string(project),
            "parent": .string(parent ?? "main"), "parentId": parent.map { .string(id($0)) } ?? .null,
            "description": .string(description), "subject": .string(subject), "commits": 1, "outline": [.string(subject)],
            "tip": .string(tip(name)), "tree": .string(tip(name)), "pushed": "local", "ahead": 0, "gates": "green", "redGates": [],
            "order": .number(Double(order)), "holdUntil": .null, "behind": 0, "drifted": false, "upstream": "", "upstreamBad": false, "diverged": false,
        ]
    }

    static func thread(_ id: String, node: String, path: String, line: Int, author: String, body: String) -> JSONValue {
        [
            "id": .string(id), "repo": .string(repo), "branch": .string(root), "pr": 1, "node": .string(node), "path": .string(path),
            "line": .number(Double(line)), "startLine": .null, "originalLine": .number(Double(line)), "originalStartLine": .null, "side": "RIGHT",
            "subject": "LINE", "outdated": false, "resolved": false, "canResolve": true, "canUnresolve": false, "canReply": true,
            "comments": [[
                "id": .string("C\(node)"), "db": 1, "author": .string(author), "state": "SUBMITTED", "body": .string(body),
                "at": "2026-10-29T12:00:00Z", "url": .string("https://github.invalid/practice/pull/1#\(node)"),
                "commit": .string(tip(root)), "originalCommit": .string(tip(root)), "hunk": "",
            ]],
            "local": ["line": .number(Double(line))], "note": .null, "fixedBy": [],
        ]
    }

    static func todo(_ id: String, _ title: String, rank: Int, why: String) -> JSONValue {
        ["id": .string(id), "title": .string(title), "kind": "build", "state": "open", "area": "practice", "size": "S", "why": .string(why),
         "links": [], "rank": .number(Double(rank)), "created": "2026-10-29", "updated": "2026-10-29", "body": .string("A practice item: \(why).")]
    }

    static func snapshot() -> JSONValue {
        let gid = greetings, fid = farewells
        let branches: [String: JSONValue] = [
            id(root): branch(root, project: gid, parent: nil, order: 1, description: "adds a greeting the pages can share", subject: "feat: add greeting"),
            id(header): branch(header, project: gid, parent: root, order: 2, description: "greets you in the header", subject: "feat: use greeting in header"),
            id(footer): branch(footer, project: gid, parent: root, order: 3, description: "greets you in the footer", subject: "feat: use greeting in footer"),
            id(banner): branch(banner, project: gid, parent: header, order: 4, description: "waves from the banner", subject: "feat: wave in the banner"),
            id(farewell): branch(farewell, project: fid, parent: nil, order: 1, description: "says goodbye on the way out", subject: "feat: add farewell"),
        ]
        let url = "https://github.invalid/practice/pull/1"
        let entities: JSONValue = [
            "repo": [repo: ["id": .string(repo), "name": .string(repo), "main": "main", "trunk": .string(trunk)]],
            "warm": [repo: ["id": .string(repo), "prs": true]],
            "project": [
                gid: ["id": .string(gid), "repo": .string(repo), "name": "greetings", "state": "focus", "rank": 1, "ticket": .null,
                               "summary": "says hello across the site", "size": 4],
                fid: ["id": .string(fid), "repo": .string(repo), "name": "farewells", "state": "focus", "rank": 2, "ticket": .null,
                               "summary": "says goodbye on the way out", "size": 1],
            ],
            "branch": .object(branches),
            "pr": [id(root): ["id": .string(id(root)), "repo": .string(repo), "branch": .string(root), "project": .string(gid), "number": 1,
                                       "url": .string(url), "state": "OPEN", "review": "REVIEW_REQUIRED", "draft": false, "base": "main",
                                       "approvals": 0, "mergeState": "BLOCKED", "mergeable": "MERGEABLE", "approvedAt": .null, "title": .null]],
            "conv": [id(root): ["id": .string(id(root)), "repo": .string(repo), "branch": .string(root), "number": 1,
                                         "title": "feat: add greeting", "body": "adds a greeting the pages can share", "url": .string(url),
                                         "author": "rowan", "state": "OPEN", "headRef": .string(root), "base": "main", "head": .string(tip(root)),
                                         "tip": .string(tip(root)), "mapping": "same", "behind": 0, "unpushed": [], "viewer": "you",
                                         "reviews": [], "comments": [], "pending": .null, "unflagged": .null, "at": 1793313911]],
            "thread": [
                thread1: thread(thread1, node: "T1", path: "greet.ts", line: 4, author: "rowan",
                                         body: "a default reads better here:\n```suggestion\nexport function hello(who = name) {\n```"),
                thread2: thread(thread2, node: "T2", path: "header.ts", line: 4, author: "rowan", body: "should the header greet a friend, or you?"),
            ],
            "draft": [id(root): ["id": .string(id(root)), "repo": .string(repo), "branch": .string(root), "items": []]],
            "todo": [
                "water-the-ferns": todo("water-the-ferns", "Water the ferns", rank: 1, why: "they droop by noon"),
                "sweep-the-porch": todo("sweep-the-porch", "Sweep the porch", rank: 2, why: "leaves everywhere"),
                "write-the-welcome": todo("write-the-welcome", "Write the welcome note", rank: 3, why: "guests on Friday"),
            ],
        ]
        return ["epoch": "keytutor", "versions": ["git": 1, "remote": 1, "review": 1, "todo": 1], "entities": entities, "ms": 1]
    }

    // ── the canned diffs (GET /node?branch=) ──

    static let diffs: [String: [(path: String, patch: String)]] = [
        root: [
            ("greet.ts", [
                "@@ -1,6 +1,8 @@",
                " export const name = \"world\"",
                "-export function hello() {",
                "-  return \"hi\"",
                "+export const greeting = \"hello\"",
                "+",
                "+export function hello(who: string = name) {",
                "+  return `${greeting}, ${who}`",
                " }",
                " ",
                " export function farewell() {",
                "@@ -20,3 +22,4 @@ export function wave() {",
                "   const hand = \"o/\"",
                "-  return hand",
                "+  const both = \"\\o/\"",
                "+  return both",
                " }",
            ].joined(separator: "\n")),
            ("header.ts", [
                "@@ -1,3 +1,4 @@",
                " import { hello } from \"./greet\"",
                "+import { greeting } from \"./greet\"",
                " ",
                "-export const header = () => \"Welcome\"",
                "+export const header = () => hello(\"friend\")",
            ].joined(separator: "\n")),
            ("README.md", [
                "@@ -1,2 +1,3 @@",
                " # practice",
                "-A small garden of greetings.",
                "+A small garden of greetings,",
                "+and one wave.",
            ].joined(separator: "\n")),
        ],
        header: [("header.ts", "@@ -1,2 +1,2 @@\n import { hello } from \"./greet\"\n-export const header = () => \"Welcome\"\n+export const header = () => hello(\"friend\")")],
        footer: [("footer.ts", "@@ -1,2 +1,2 @@\n import { hello } from \"./greet\"\n-export const footer = () => \"Bye\"\n+export const footer = () => hello(\"again\")")],
        banner: [("banner.ts", "@@ -0,0 +1,2 @@\n+import { wave } from \"./greet\"\n+export const banner = () => wave()")],
        farewell: [("farewell.ts", "@@ -0,0 +1,2 @@\n+export const goodbye = \"see you\"\n+export const farewell = () => goodbye")],
    ]

    static func node(_ branch: String) -> JSONValue {
        let files = (diffs[branch] ?? []).map { f -> JSONValue in
            let add = f.patch.split(separator: "\n").filter { $0.hasPrefix("+") }.count
            let del = f.patch.split(separator: "\n").filter { $0.hasPrefix("-") }.count
            return ["path": .string(f.path), "add": .number(Double(add)), "del": .number(Double(del)), "patch": .string(f.patch)]
        }
        return ["branch": .string(branch), "baseSha": .string(trunk), "files": .array(files)]
    }

    /// A file at a commit (gaps, the side pane): numbered practice lines.
    static func file(_ path: String) -> String { (1...40).map { "// \(path) line \($0)" }.joined(separator: "\n") }

    /// Every answer the practice server gives. GETs it doesn't know are a 404 (pages show "nothing
    /// yet"); every write "lands" — the optimistic change stays, nothing anywhere moved.
    static func answer(method: String, path: String, query: [String: String]) -> (Int, String) {
        let tail = path.hasPrefix("/\(repo)/") ? String(path.dropFirst(repo.count + 1)) : path
        let b = query["branch"] ?? root
        switch (method, tail) {
        case ("GET", "/node"): return (200, json(node(b)))
        case ("GET", "/file"), ("GET", "/lsp/src"): return (200, file(query["path"] ?? "x.ts"))
        case ("GET", "/sync"): return (200, #"{"behind":1,"syncable":true,"restack":false,"published":false,"dirty":[],"dirtyWorktree":"","why":""}"#)
        case ("GET", "/commits"):
            return (200, #"[{"sha":"\#(tip(b))","subject":"feat: add greeting","author":"you","date":"2026-10-29","body":"","own":true}]"#)
        case ("GET", "/outline"):
            let t = tip(b)
            return (200, #"{"ok":true,"branch":"\#(b)","parent":"main","base":"origin/main","head":"\#(t)","description":"adds a greeting the pages can share","story":"","ticket":"","commits":[{"sha":"\#(t)","short":"\#(t.prefix(10))","subject":"feat: add greeting","body":"","author":"you","date":"2026-10-29","pushed":false,"merge":false,"carried":false,"locked":"","files":3,"add":9,"del":5}],"pr":{"exists":false},"draft":{"title":"feat: add greeting","titleSaved":false,"body":"so every page can say hello the same way","bodySaved":false,"derivedBody":null,"bodyPending":false},"reseat":null,"undo":null}"#)
        case ("GET", "/learning-state"): return (200, learning)
        case ("POST", "/lsp/hover"): return (200, #"{"ok":true,"contents":"```ts\nconst greeting: \"hello\"\n```"}"#)
        case ("POST", "/lsp/definition"), ("POST", "/lsp/type-definition"), ("POST", "/lsp/implementation"):
            return (200, #"{"ok":true,"sha":"\#(tip(root))","locations":[{"path":"greet.ts","line":2,"character":13}]}"#)
        case ("POST", "/lsp/references"):
            return (200, #"{"ok":true,"sha":"\#(tip(root))","locations":[{"path":"greet.ts","line":2,"character":13},{"path":"header.ts","line":2,"character":9}]}"#)
        case ("POST", "/lsp/symbols"):
            return (200, #"{"ok":true,"sha":"\#(tip(root))","symbols":[{"name":"name","kind":"const","line":1,"endLine":1,"depth":0},{"name":"greeting","kind":"const","line":2,"endLine":2,"depth":0},{"name":"hello","kind":"function","line":4,"endLine":6,"depth":0}]}"#)
        case ("POST", "/review-apply"): return (200, #"{"ok":true,"sha":"ab12cd"}"#)
        case ("POST", "/sync"): return (200, #"{"ok":true,"rebased":true,"summary":"replayed 1 commit (practice)"}"#)
        case ("POST", _): return (200, #"{"ok":true}"#)
        default: return (404, "{}")
        }
    }

    /// The Socratic tutor's practice graph: enough for its home page's stacked panes to show.
    static let learning = #"""
    {"concepts": {
      "keys-belong-to-verbs": {"name": "Keys belong to verbs", "statement": "A key means one verb on every page.", "kind": "principle",
        "builds_on": [], "analogs": [], "code": [], "topics": ["canopy-keys"], "id": "keys-belong-to-verbs",
        "mastery": {"depth": 1, "assisted": 0, "level": "explain", "held": 0, "evidence": 1, "last": "2026-10-28", "due": true,
          "reason": "practice", "open_miss": "", "misses": 0}, "built_on_by": ["esc-only-cancels"], "blocked_by": []},
      "esc-only-cancels": {"name": "esc only cancels", "statement": "esc backs out one level and never changes page.", "kind": "principle",
        "builds_on": ["keys-belong-to-verbs"], "analogs": [], "code": [], "topics": ["canopy-keys"], "id": "esc-only-cancels",
        "mastery": {"depth": 0, "assisted": 0, "level": "", "evidence": 0, "last": "", "due": true, "reason": "practice", "open_miss": ""},
        "built_on_by": [], "blocked_by": []}
     },
     "topics": {"canopy-keys": {"title": "canopy's keys", "source": "the keytutor",
       "stages": [{"name": "Verbs", "concepts": ["keys-belong-to-verbs", "esc-only-cancels"]}],
       "created": "2026-10-29", "updated": "2026-10-29", "id": "canopy-keys", "progress": {"held": 0, "shown": 1, "total": 2}}},
     "due": ["keys-belong-to-verbs", "esc-only-cancels"],
     "systems": {}, "standards": {}, "standards_due": [],
     "questions": [{"id": "q1", "text": "Why can't a page bind a raw key?", "concept": "keys-belong-to-verbs", "topic": "canopy-keys", "asked": "2026-10-29", "status": "open"}],
     "calibration": [], "evidence": [], "levels": [], "credits": [], "confidences": [], "rungs": [], "sources": [], "today": "2026-10-29"}
    """#

    private static func json(_ v: JSONValue) -> String { String(decoding: try! JSONEncoder().encode(v), as: UTF8.self) }
}

extension Scope {
    /// The keytutor's own keys, live on every page of its practice app (`AppModel.alwaysLive`).
    static let practice: Scope = "practice"
}

/// The practice server: a URLProtocol that answers every request of a practice app from
/// `KeyTutorSandbox.answer` and keeps a log of what was asked (and what would have opened or been
/// copied), per practice app. Nothing it sees goes anywhere.
final class KeyTutorStub: URLProtocol, @unchecked Sendable {
    struct Seen: Equatable, Sendable {
        var method: String
        var host: String
        var port: Int
        var path: String
    }

    nonisolated(unsafe) private static var seen: [Int: [Seen]] = [:]
    nonisolated(unsafe) private static var notes: [Int: [String]] = [:]
    private static let lock = NSLock()

    static func open(_ port: Int) { lock.withLock { seen[port] = []; notes[port] = [] } }
    static func requests(_ port: Int) -> [Seen] { lock.withLock { seen[port] ?? [] } }
    /// What would have left the practice app another way (a browser, the clipboard), said instead.
    static func note(_ port: Int, _ s: String) { lock.withLock { notes[port, default: []].append(s) } }
    static func notes(_ port: Int) -> [String] { lock.withLock { notes[port] ?? [] } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let method = request.httpMethod ?? "GET"
        let port = url.port ?? 0
        Self.lock.withLock { Self.seen[port, default: []].append(Seen(method: method, host: url.host ?? "", port: port, path: url.path)) }
        var query: [String: String] = [:]
        for q in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] { query[q.name] = q.value ?? "" }
        let (status, body) = KeyTutorSandbox.answer(method: method, path: url.path, query: query)
        let resp = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// UserDefaults that live in memory only: the practice app's remembered face and unsent words.
final class MemoryDefaults: UserDefaults, @unchecked Sendable {
    private var values: [String: Any] = [:]

    convenience init() { self.init(suiteName: "canopy-native.keytutor.memory")! }

    override func object(forKey key: String) -> Any? { values[key] }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
    override func removeObject(forKey key: String) { values[key] = nil }
    override func string(forKey key: String) -> String? { values[key] as? String }
}
