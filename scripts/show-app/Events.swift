import Foundation

/// What Show can put in front of you: a document (deck, tutor session, live run), a canopy page, or the API console.
enum Target: Hashable {
    case document(String)
    /// A canopy address (`/v2/…`); empty is canopy's home.
    case canopy(String)
    case api

    /// One string per target: a document's path, `canopy:<route>`, or `api:`. History rows and notifications carry it.
    var key: String {
        switch self {
        case .document(let path): return path
        case .canopy(let route): return "canopy:" + route
        case .api: return "api:"
        }
    }

    init(key: String) {
        if key == "api:" {
            self = .api
        } else if key.hasPrefix("canopy:") {
            self = .canopy(String(key.dropFirst("canopy:".count)))
        } else {
            self = .document(key)
        }
    }

    /// A `canopy://v2/…` link as the address canopy routes (`/v2/…`).
    init(canopyLink link: URL) {
        let rest = link.absoluteString.dropFirst("canopy:".count).drop { $0 == "/" }
        self = .canopy(rest.isEmpty ? "" : "/" + rest)
    }

    var workspace: Workspace {
        switch self {
        case .document(let path): return Workspace.route(path).workspace
        case .canopy: return .canopy
        case .api: return .api
        }
    }
}

extension Target: Codable {
    private enum Keys: String, CodingKey {
        case document, canopy, api
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        if let path = try c.decodeIfPresent(String.self, forKey: .document) {
            self = .document(path)
        } else if let route = try c.decodeIfPresent(String.self, forKey: .canopy) {
            self = .canopy(route)
        } else if c.contains(.api) {
            self = .api
        } else {
            throw DecodingError.dataCorrupted(.init(codingPath: c.codingPath, debugDescription: "a target names document, canopy or api"))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .document(let path): try c.encode(path, forKey: .document)
        case .canopy(let route): try c.encode(route, forKey: .canopy)
        case .api: try c.encode(true, forKey: .api)
        }
    }
}

extension Workspace: Codable {}

/// One request to put something in front of you, from any door: the launchers' inbox files, a canopy:// link, a file opened
/// from Finder or the command line. Who asked and what they want decide whether Show comes forward (`comesForward`).
struct ShowRequest: Codable {
    enum Actor: String, Codable {
        case phil, session
    }

    enum Intent: String, Codable {
        /// Leave it waiting: a notification and a badge, nothing moves.
        case deliver
        /// Phil asked to see it now.
        case showNow
    }

    let target: Target
    let actor: Actor
    var session: String? = nil
    let intent: Intent

    /// Anything Phil opens himself, from Finder, a link or his terminal.
    static func phil(_ target: Target) -> ShowRequest {
        ShowRequest(target: target, actor: .phil, intent: .showNow)
    }
}

/// The one rule for taking the screen: Show comes forward and opens the target only when Phil asked, himself or through a
/// session he told to show him. Everything else arrives: it waits in History and on a badge, with a notification.
func comesForward(_ request: ShowRequest) -> Bool {
    request.actor == .phil || request.intent == .showNow
}

/// The launchers' drop box: `show` writes one request file here per call and hands it to the app, which reads and deletes it.
let inboxDirectory = ProcessInfo.processInfo.environment["SHOW_INBOX"]
    ?? ((Bundle.main.bundlePath as NSString).deletingLastPathComponent as NSString).appendingPathComponent("inbox")

/// The request an inbox file holds, deleting the file; nil for any other path.
func takeInboxRequest(_ path: String) -> ShowRequest? {
    guard canonicalPath((path as NSString).deletingLastPathComponent) == canonicalPath(inboxDirectory) else { return nil }
    defer { try? FileManager.default.removeItem(atPath: path) }
    guard let data = FileManager.default.contents(atPath: path) else { return nil }
    return try? JSONDecoder().decode(ShowRequest.self, from: data)
}

/// Something that happened in front of you. Show appends these to `events.jsonl` and never edits one; where you are, what
/// waits, the back stacks and History are all read from them (`ShowState`).
struct ShowEvent: Codable, Equatable {
    enum Kind: String, Codable {
        /// A session sent it; it waits until opened or dismissed.
        case arrived
        case opened
        /// Archived or forgotten: it leaves the back stack and stops waiting.
        case dismissed
    }

    var at = Date()
    let kind: Kind
    let target: Target
    let workspace: Workspace
    let title: String
    /// The sending session, for an arrival; its topic is looked up when shown.
    var session: String? = nil
    /// An open made by ⌘[, which steps down the back stack instead of pushing onto it.
    var back: Bool? = nil
}

/// The fold of the event log: what each workspace has open, what it would go back to, what waits on you, and when each
/// target was last touched. `apply` is pure, so replaying the same events always gives the same state.
struct ShowState: Equatable {
    static let backDepth = 50
    var current: [Workspace: Target] = [:]
    var back: [Workspace: [Target]] = [:]
    /// Arrivals not yet opened or dismissed, oldest first.
    var waiting: [Target] = []
    var touched: [Target: Date] = [:]

    mutating func apply(_ event: ShowEvent) {
        let workspace = event.workspace
        switch event.kind {
        case .arrived:
            waiting.removeAll { $0 == event.target }
            waiting.append(event.target)
            touched[event.target] = event.at
        case .opened:
            waiting.removeAll { $0 == event.target }
            touched[event.target] = event.at
            var stack = back[workspace] ?? []
            if event.back == true {
                while let popped = stack.popLast(), popped != event.target {}
            } else if case .document = event.target, let previous = current[workspace], previous != event.target, stack.last != previous {
                stack.append(previous)
                stack = Array(stack.suffix(Self.backDepth))
            }
            back[workspace] = stack
            current[workspace] = event.target
        case .dismissed:
            waiting.removeAll { $0 == event.target }
            back[workspace]?.removeAll { $0 == event.target }
            if current[workspace] == event.target {
                current[workspace] = nil
            }
        }
    }

    static func fold(_ events: [ShowEvent]) -> ShowState {
        var state = ShowState()
        events.forEach { state.apply($0) }
        return state
    }
}

/// `events.jsonl`, one event per line, appended and never rewritten except to drop the oldest lines once it passes
/// `limit`. Sessions may read it (`show --status <target>`); only the app writes it. `SHOW_EVENTS` points it elsewhere.
final class EventLog {
    static let limit = 5000
    let path: String
    private(set) var events: [ShowEvent] = []
    private(set) var state = ShowState()
    var onChange: (() -> Void)?

    init(path: String) {
        self.path = path
        load()
    }

    private func load() {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            seedFromPreferences()
            return
        }
        let decoder = Self.decoder
        events = text.split(separator: "\n").compactMap { try? decoder.decode(ShowEvent.self, from: Data($0.utf8)) }
        if events.count > Self.limit + Self.limit / 4 {
            events = Array(events.suffix(Self.limit))
            rewrite()
        }
        state = ShowState.fold(events)
    }

    /// Records `event`, unless it's an open of what its workspace already has open (a reload, a relaunch's restore).
    @discardableResult
    func append(_ event: ShowEvent) -> Bool {
        if event.kind == .opened, event.back != true, state.current[event.workspace] == event.target, !state.waiting.contains(event.target) {
            return false
        }
        events.append(event)
        state.apply(event)
        write([event], append: true)
        onChange?()
        return true
    }

    private func rewrite() {
        write(events, append: false)
    }

    private func write(_ batch: [ShowEvent], append: Bool) {
        let encoder = Self.encoder
        let lines = batch.compactMap { try? encoder.encode($0) }.map { String(decoding: $0, as: UTF8.self) + "\n" }.joined()
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard append, let handle = try? FileHandle(forWritingTo: url) else {
            try? lines.write(to: url, atomically: true, encoding: .utf8)
            return
        }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(lines.utf8))
    }

    /// The first run on a machine that kept where-you-were in preferences: each workspace's back stack, then its open
    /// document, become opens, so nothing is lost when the log takes over.
    private func seedFromPreferences() {
        var seeded: [ShowEvent] = []
        for workspace in Workspace.allCases where ![.api, .canopy, .machine].contains(workspace) {
            let stack = prefs.stringArray(forKey: "workspace.\(workspace.rawValue).back") ?? []
            let open = prefs.string(forKey: "workspace.\(workspace.rawValue).open")
            for path in stack + [open].compactMap({ $0 }) {
                let at = (prefs.object(forKey: "opened." + path) as? Date) ?? Date(timeIntervalSince1970: 0)
                seeded.append(ShowEvent(at: at, kind: .opened, target: .document(path), workspace: workspace, title: (path as NSString).lastPathComponent))
            }
        }
        events = seeded
        state = ShowState.fold(seeded)
        rewrite()
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

let eventsPath = ProcessInfo.processInfo.environment["SHOW_EVENTS"]
    ?? ("~/Library/Application Support/Show/events.jsonl" as NSString).expandingTildeInPath

/// The app's one event log, opened on first use (after the selftest or a snapshot has pointed `SHOW_EVENTS` and `prefs` at scratch).
let showEvents = EventLog(path: eventsPath)

/// How a canopy route reads in a notification or History: `/v2/p/loops/notice-charts` → "Forest notice-charts".
func canopyTitle(_ route: String) -> String {
    let parts = route.split(separator: "?").first.map { $0.split(separator: "/").map(String.init) } ?? []
    guard parts.first == "v2" || parts.isEmpty else { return route }
    guard parts.count >= 4 else { return parts.count > 1 ? "Canopy \(parts[1])" : "Canopy home" }
    let name = parts[3...].joined(separator: "/")
    switch parts[1] {
    case "p": return "Forest \(name)"
    case "b": return "Branch \(name)"
    default: return route
    }
}

/// History's rows, newest first: ◆ still waiting, ● opened or since seen, with the workspace, the sender's topic and the time.
func historyEntries(_ log: EventLog) -> [ShelfEntry] {
    let ago = RelativeDateTimeFormatter()
    ago.unitsStyle = .short
    return log.events.reversed().filter { $0.kind != .dismissed && $0.target != .api }.map { event in
        let detail = [event.workspace.name, event.kind.rawValue, Topics.cached(event.session), ago.localizedString(for: event.at, relativeTo: Date())]
        let waiting = event.kind == .arrived && log.state.waiting.contains(event.target)
        return ShelfEntry(path: event.target.key, workspace: event.workspace, title: event.title, state: waiting ? .waiting : .done,
                          progress: detail.compactMap { $0 }.joined(separator: " · "), touched: event.at)
    }
}
