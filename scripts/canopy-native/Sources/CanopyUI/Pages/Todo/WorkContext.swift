import CanopyCore
import Foundation

struct RecordedWorkInput: Equatable {
    enum Source: String { case chat, review }

    let at: Date
    let source: Source
    let text: String
    let notes: String

    static func read(_ body: String) -> RecordedWorkInput? {
        let lines = body.components(separatedBy: .newlines)
        guard lines.first == "## Your input", lines.count > 4, lines[1].isEmpty else { return nil }
        let fields = lines[2].components(separatedBy: " · ")
        guard fields.count == 2, let at = parseISO(fields[0]), let source = Source(rawValue: fields[1]), lines[3].isEmpty else { return nil }
        var end = 4, quote: [String] = []
        while end < lines.count {
            let line = lines[end]
            if line == ">" { quote.append("") }
            else if line.hasPrefix("> ") { quote.append(String(line.dropFirst(2))) }
            else { break }
            end += 1
        }
        guard !quote.joined().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              end == lines.count || lines[end].isEmpty else { return nil }
        let notes = lines.dropFirst(end).joined(separator: "\n").trimmingCharacters(in: .newlines)
        return RecordedWorkInput(at: at, source: source, text: quote.joined(separator: "\n"), notes: notes)
    }

    static func chat(in body: String) -> RecordedWorkInput? {
        guard let input = read(body), input.source == .chat else { return nil }
        return input
    }

    var when: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "MMM d, yyyy HH:mm 'UTC'"
        return formatter.string(from: at)
    }
}

struct WorkContext {
    enum Subject: Equatable {
        case viewer
        case forest(String)
        case branch(project: String, name: String)

        var key: String {
            switch self {
            case .viewer: "viewer"
            case .forest(let id): "forest:\(id.utf8.count):\(id)"
            case .branch(let project, let name): "branch:\(project.utf8.count):\(project)\(name)"
            }
        }
    }

    let items: [TodoItem]

    init(_ items: [TodoItem], subject: Subject) {
        self.items = items.filter {
            switch subject {
            case .viewer: return $0.project == nil
            case .forest(let id): return $0.project == id
            case .branch(let project, let name): return $0.project == project && $0.solved_by == name
            }
        }
    }

    var doing: [TodoItem] { items.filter { $0.state == .doing }.sorted(by: Tracker.byQueue) }

    /// Items the tracker calls done whose work journal holds direction no qualified completion answered: they need work
    /// again, whatever the tracker file says, so they sit with the work in progress. Unknown capture coverage doesn't
    /// erase a known unanswered instruction; an unreadable journal claims nothing.
    var reopened: [TodoItem] { items.filter(Self.reopened).sorted(by: Tracker.byQueue) }

    static func reopened(_ item: TodoItem) -> Bool {
        guard item.state == .done, let w = item.work, w.state != "unavailable", let revision = w.revision else { return false }
        return w.state == "pending" || revision > (w.answeredRevision ?? 0)
    }

    /// What an item's latest direction is: the journal's literal message when the journal records the item, otherwise the
    /// older recorded `## Your input` section, which stays a legacy convention with no capture guarantee.
    enum Direction: Equatable {
        case journal(WorkFreshness.Latest)
        case recorded(RecordedWorkInput)

        var text: String {
            switch self {
            case .journal(let l): l.text
            case .recorded(let r): r.text
            }
        }

        var date: Date? {
            switch self {
            case .journal(let l): (l.sourceTime.flatMap(parseISO)) ?? parseISO(l.receivedAt)
            case .recorded(let r): r.at
            }
        }
    }

    static func direction(_ item: TodoItem) -> Direction? {
        if let work = item.work, work.state != "unavailable" { return work.latest.map(Direction.journal) }
        return RecordedWorkInput.chat(in: item.body).map(Direction.recorded)
    }

    /// The scope's most recently given direction, one item's; each item's own latest is by its source order.
    var latestDirection: (item: TodoItem, direction: Direction)? {
        items.compactMap { item in Self.direction(item).map { (item: item, direction: $0) } }
            .sorted { a, b in
                let x = a.direction.date ?? .distantPast, y = b.direction.date ?? .distantPast
                return x != y ? x > y : a.item.id < b.item.id
            }.first
    }

    /// What the scope's work context presents: the latest direction's item, or — when no single latest message exists
    /// (direction across conversations, an unreadable journal, nothing captured yet) — one work-backed item with its own
    /// facts and no message: reopened work first, then work in progress, then the queue. Nil only when no item has
    /// either, the legacy case of no recorded work.
    var presentation: (item: TodoItem, direction: Direction?)? {
        if let latest = latestDirection { return (latest.item, latest.direction) }
        let backed = items.filter { $0.work != nil }.sorted { a, b in
            let rank = { (t: TodoItem) in Self.reopened(t) ? 0 : t.state == .doing ? 1 : 2 }
            return rank(a) != rank(b) ? rank(a) < rank(b) : Tracker.byQueue(a, b)
        }
        return backed.first.map { ($0, nil) }
    }

    /// One line of an item's work freshness, every fact from its own source: direction revision, delivery, the worker
    /// as observed, and what a completion answers. Delivery means the host received the direction, not that it was followed.
    static func freshness(_ w: WorkFreshness) -> String {
        if w.state == "unavailable" { return "work journal unreadable · freshness unknown" }
        var parts: [String] = []
        if let rev = w.revision { parts.append("direction r\(rev)" + ((w.inForce ?? 0) > 1 ? " · \(w.inForce!) instructions in force" : "")) }
        if let d = w.delivered {
            let how = ["acknowledged": "confirmed", "uncertain": "unconfirmed", "failed": "failed", "sending": "sending"][d.state] ?? d.state
            parts.append("delivered r\(d.revision) \(how)")
        } else {
            parts.append("not delivered")
        }
        if let worker = w.worker {
            switch worker.state {
            case "running": parts.append("worker running")
            case "ended": parts.append("worker ended" + (worker.outcome.map { " (\($0))" } ?? ""))
            case "none": parts.append("no turn yet")
            default: parts.append("worker state unknown")
            }
        }
        let answered = w.answeredRevision.map { "r\($0)" } ?? "an earlier revision"
        switch w.state {
        case "answered":
            parts.append("done for r\(w.revision ?? 0)")
        case "pending":
            if w.answeredRevision != nil { parts.append("done for \(answered) · newer direction pending") }
            switch w.completion {
            case "historical": break
            case "stale": parts.append(w.answeredRevision != nil ? "last report stale" : "last completion stale")
            case "unverified": parts.append(w.answeredRevision != nil ? "last report unverified" : "completion unverified")
            default: if w.answeredRevision == nil { parts.append("not completed") }
            }
        default:
            let unanswered = (w.revision ?? 0) > (w.answeredRevision ?? 0)
            parts.append("capture \(w.coverage ?? "unknown") · freshness unknown"
                         + (w.answeredRevision != nil ? " · done recorded for \(answered)" : "") + (unanswered ? " · newer direction pending" : ""))
        }
        return parts.joined(separator: " · ")
    }

    static func progress(_ p: WorkFreshness.Progress) -> String {
        let basis = ["current": "on the current direction", "older": "on older direction", "earlier-attempt": "from an earlier attempt",
                     "unverified": "unverified"][p.basis] ?? p.basis
        return "progress \(instant(p.at)) · \(basis)"
    }

    /// An ISO-8601 timestamp as a UTC minute, whatever offset it was written with; a string that isn't one is shown as given.
    static func instant(_ iso: String) -> String {
        guard let date = parseISO(iso) else { return "at \"\(iso)\" (time not understood)" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm 'UTC'"
        return formatter.string(from: date)
    }

    var latestInput: (item: TodoItem, input: RecordedWorkInput)? {
        items.compactMap { item in RecordedWorkInput.chat(in: item.body).map { (item: item, input: $0) } }
            .sorted { $0.input.at != $1.input.at ? $0.input.at > $1.input.at : $0.item.id < $1.item.id }.first
    }

    var updated: String? { items.compactMap { Self.day($0.updated) }.max() }

    var summary: String {
        var parts: [String] = []
        if !doing.isEmpty { parts.append("\(doing.count) in progress") }
        if !reopened.isEmpty { parts.append("\(reopened.count) with new direction") }
        let waiting = items.filter { $0.state == .waiting }.count
        let decisions = items.filter { Tracker.sectionOf($0) == .decide }.count
        if decisions > 0 { parts.append("\(decisions) need you") }
        if waiting > 0 { parts.append("\(waiting) waiting") }
        if parts.isEmpty { parts.append("\(items.filter { Tracker.sectionOf($0) != nil }.count) open") }
        return parts.joined(separator: " · ")
    }

    static func day(_ value: String?) -> String? {
        guard let value, value.count == 10 else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let date = formatter.date(from: value), formatter.string(from: date) == value else { return nil }
        return value
    }

    static func status(_ item: TodoItem) -> String {
        switch item.state {
        case .doing: "marked in progress"
        case .waiting: "waiting" + (item.waiting?.isEmpty == false ? " on \(item.waiting!)" : "")
        case .done: reopened(item) ? "marked done · new direction since" : "done"
        case .dropped: "dropped"
        case .broken: "can't read"
        case .open: item.kind == "decide" ? "needs you" : "queued"
        default: "state: \(item.state.rawValue)"
        }
    }

    /// What the work is doing now, in its own words: the first of its next steps, else why it exists.
    static func doingNow(_ item: TodoItem) -> String? {
        let lines = item.body.components(separatedBy: .newlines)
        if let head = lines.firstIndex(of: "## Next steps") {
            for line in lines[(head + 1)...] {
                if line.hasPrefix("## ") { break }
                let t = line.trimmingCharacters(in: .whitespaces)
                if let r = t.range(of: #"^([-*]|\d+[.)])\s+(\[[ x]\]\s+)?"#, options: .regularExpression) {
                    let step = String(t[r.upperBound...]).replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
                    if !step.isEmpty { return step }
                }
            }
        }
        let why = item.why.trimmingCharacters(in: .whitespacesAndNewlines)
        return why.isEmpty ? nil : why
    }

    /// In-progress items by the forest branch they record solving (`solved_by`), keyed by branch id. An item on a
    /// forest's own list only lands on that forest's branch; a viewer item lands on the one branch with its name.
    static func onBranches(_ items: [TodoItem], _ branches: [Branch]) -> [String: [TodoItem]] {
        var out: [String: [TodoItem]] = [:]
        for item in items {
            guard let name = item.solved_by else { continue }
            let hits = branches.filter { $0.name == name && (item.project == nil || item.project == $0.project) }
            if hits.count == 1 { out[hits[0].id, default: []].append(item) }
        }
        return out
    }

    /// The owner's short session id and the tracker's day, the facts a working line can state.
    @MainActor static func workedBy(_ item: TodoItem, _ store: Store) -> String {
        let owner = store.rawView("todo", item.id)?["owner"]?.string.flatMap { $0.isEmpty ? nil : "session \($0)" }
        let since = day(item.updated).map { "updated \(String($0.dropFirst(5)))" }
        return [owner, since].compactMap { $0 }.joined(separator: " · ")
    }

    static func updateLabel(_ value: String?) -> String {
        day(value).map { "tracker updated \($0)" } ?? "update date not recorded"
    }

    @MainActor static func owner(_ item: TodoItem, _ store: Store) -> String? {
        guard item.state == .doing, let owner = store.rawView("todo", item.id)?["owner"]?.string,
              !owner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return "assigned to session \(owner)"
    }
}
