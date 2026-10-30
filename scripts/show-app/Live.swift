import AppKit

/// A live deck's optional run status, shown as one quiet line above the page.
struct LiveStatus: Decodable {
    let state: String?
    let done: Int?
    let total: Int?
    let current: String?

    func line(changed: Date?) -> String {
        var parts: [String] = []
        if let state, !state.isEmpty {
            parts.append(state.prefix(1).uppercased() + state.dropFirst())
        }
        if let done, let total {
            parts.append("\(done) of \(total)")
        } else if let done {
            parts.append("\(done) done")
        }
        if let current, !current.isEmpty {
            parts.append("now: \(current)")
        }
        if let changed {
            parts.append("updated \(sinceText(changed))")
        }
        return parts.joined(separator: " · ")
    }
}

func sinceText(_ date: Date) -> String {
    let seconds = max(0, Int(Date().timeIntervalSince(date)))
    if seconds < 60 { return "\(seconds)s ago" }
    if seconds < 3600 { return "\(seconds / 60)m ago" }
    return "\(seconds / 3600)h ago"
}
