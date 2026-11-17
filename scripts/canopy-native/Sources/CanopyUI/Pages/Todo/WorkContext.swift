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

    var latestInput: (item: TodoItem, input: RecordedWorkInput)? {
        items.compactMap { item in RecordedWorkInput.chat(in: item.body).map { (item: item, input: $0) } }
            .sorted { $0.input.at != $1.input.at ? $0.input.at > $1.input.at : $0.item.id < $1.item.id }.first
    }

    var updated: String? { items.compactMap { Self.day($0.updated) }.max() }

    var summary: String {
        var parts: [String] = []
        if !doing.isEmpty { parts.append("\(doing.count) in progress") }
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
        case .done: "done"
        case .dropped: "dropped"
        case .broken: "can't read"
        case .open: item.kind == "decide" ? "needs you" : "queued"
        default: "state: \(item.state.rawValue)"
        }
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
