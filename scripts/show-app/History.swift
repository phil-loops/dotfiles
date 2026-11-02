import AppKit

/// What happened in Show, newest last: each document or canopy page that arrived or was opened, in any workspace.
/// A canopy page's target is `canopy:` + its /v2/… route; a document's is its path.
struct HistoryRecord {
    enum Kind: String {
        case arrived, opened
    }

    let kind: Kind
    let target: String
    let workspace: Workspace
    let title: String
    let topic: String?
    let at: Date

    var plist: [String: Any] {
        var out: [String: Any] = ["kind": kind.rawValue, "target": target, "workspace": workspace.rawValue, "title": title, "at": at]
        if let topic { out["topic"] = topic }
        return out
    }

    init(kind: Kind, target: String, workspace: Workspace, title: String, topic: String?, at: Date = Date()) {
        self.kind = kind
        self.target = target
        self.workspace = workspace
        self.title = title
        self.topic = topic
        self.at = at
    }

    init?(_ plist: [String: Any]) {
        guard let kind = (plist["kind"] as? String).flatMap(Kind.init(rawValue:)),
              let target = plist["target"] as? String,
              let workspace = (plist["workspace"] as? String).flatMap(Workspace.init(rawValue:)),
              let title = plist["title"] as? String,
              let at = plist["at"] as? Date else { return nil }
        self.init(kind: kind, target: target, workspace: workspace, title: title, topic: plist["topic"] as? String, at: at)
    }
}

enum ShowHistory {
    static let limit = 300
    private static let key = "history"

    static var records: [HistoryRecord] {
        (prefs.array(forKey: key) as? [[String: Any]] ?? []).compactMap(HistoryRecord.init)
    }

    /// Appends `record`. Opening what its workspace last opened (a reload, a relaunch's restore) adds nothing; the same
    /// arrival again within a minute replaces the earlier line.
    static func record(_ record: HistoryRecord) {
        var all = records
        if record.kind == .opened, all.last(where: { $0.kind == .opened && $0.workspace == record.workspace })?.target == record.target {
            return
        }
        if let last = all.last, last.target == record.target, last.kind == record.kind, record.at.timeIntervalSince(last.at) < 60 {
            all.removeLast()
        }
        all.append(record)
        prefs.set(all.suffix(limit).map(\.plist), forKey: key)
    }

    /// The finder's rows, newest first: ◆ arrived, ● opened, with the workspace, the sending session's topic and the time.
    static func entries() -> [ShelfEntry] {
        let ago = RelativeDateTimeFormatter()
        ago.unitsStyle = .short
        return records.reversed().map { record in
            let detail = [record.workspace.name, record.kind.rawValue, record.topic, ago.localizedString(for: record.at, relativeTo: Date())]
            return ShelfEntry(path: record.target, workspace: record.workspace, title: record.title, state: record.kind == .arrived ? .waiting : .done,
                              progress: detail.compactMap { $0 }.joined(separator: " · "), touched: record.at)
        }
    }
}

/// Canopy pages sessions sent while you were elsewhere, oldest first. ⌘6 goes to the newest and clears them.
enum CanopyArrivals {
    private static let key = "canopy.pending"

    static var pending: [String] { prefs.stringArray(forKey: key) ?? [] }

    static func add(_ route: String) {
        prefs.set(pending.filter { $0 != route } + [route], forKey: key)
    }

    /// The newest waiting route, emptying the queue.
    static func take() -> String? {
        defer { prefs.removeObject(forKey: key) }
        return pending.last
    }

    static func remove(_ route: String) {
        prefs.set(pending.filter { $0 != route }, forKey: key)
    }
}

/// A canopy request file: `{"workspace": "canopy", "route": "/v2/…", "replyTo": "<session prefix>"}`.
struct CanopyRequest {
    let route: String?
    let replyTo: String?

    init(path: String) {
        let json = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path)))) as? [String: Any]
        route = (json?["route"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        replyTo = (json?["replyTo"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// How a canopy route reads in a notification or history line: `/v2/p/loops/notice-charts` → "Forest notice-charts".
func canopyTitle(_ route: String) -> String {
    let bare = route.hasPrefix("canopy:") ? String(route.dropFirst("canopy:".count)) : route
    let parts = bare.split(separator: "?").first.map { $0.split(separator: "/").map(String.init) } ?? []
    guard parts.count >= 4, parts[0] == "v2" else { return route.isEmpty ? "Canopy home" : route }
    let name = parts[3...].joined(separator: "/")
    switch parts[1] {
    case "p": return "Forest \(name)"
    case "b": return "Branch \(name)"
    default: return route
    }
}
