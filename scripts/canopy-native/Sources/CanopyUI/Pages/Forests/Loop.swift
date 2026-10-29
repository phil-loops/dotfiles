import CanopyCore
import Foundation

// The dev loop as one strip — words ▸ gates ▸ push ▸ PR ▸ review ▸ merged — so a page says where the
// branch is and what stands in the way, without reading three surfaces. Pure (loop.ts).

public struct LoopStep: Equatable, Sendable {
    public enum ID: String, Sendable, CaseIterable { case words, gates, push, pr, review, merged }
    public enum State: String, Sendable { case done, now, later }
    public var id: ID
    public var state: State
    /// what this step waits on, when it's the one in the way
    public var note: String?
    /// words only: something to fix that doesn't stop the loop
    public var flag: Bool?

    public init(id: ID, state: State, note: String? = nil, flag: Bool? = nil) {
        self.id = id; self.state = state; self.note = note; self.flag = flag
    }

    public var word: String { id == .pr ? "PR" : id.rawValue }
}

/// One outline hint as the loop reads it (outlineHints.ts Hint: its id and tone).
public struct LoopWord: Equatable, Sendable {
    public var id: String
    /// "error" | "warn" | "note" — a note never flags
    public var tone: String
    public init(id: String, tone: String) { self.id = id; self.tone = tone }
}

public enum Loop {
    static let order: [LoopStep.ID] = [.gates, .push, .pr, .review, .merged]

    /// Each step's state; `words` are the title and body hints, which flag but never block — nil
    /// while they're unread, which leaves the step out rather than claim it's clean.
    public static func steps(_ b: Branch, _ pr: Pr?, _ st: Stand, words: [LoopWord]?) -> [LoopStep] {
        let merged = st.ship == .landed
        let done: [LoopStep.ID: Bool] = [
            .gates: b.gates == .green || (st.ship != .local && b.pushed != .ahead),
            .push: st.ship != .local && st.ship != .green && b.pushed != .ahead,
            .pr: pr != nil,
            .review: st.ship == .approved || merged,
            .merged: merged,
        ]
        let now = order.first { !(done[$0] ?? false) }
        var steps = order.map { LoopStep(id: $0, state: done[$0] == true ? .done : $0 == now ? .now : .later) }
        if let i = steps.firstIndex(where: { $0.state == .now }) { steps[i].note = note(steps[i].id, b, pr, st) }
        guard let words else { return steps }
        let wrong = words.filter { $0.tone != "note" }
        let w: LoopStep = pr != nil
            ? LoopStep(id: .words, state: .done)
            : LoopStep(id: .words, state: wrong.isEmpty ? .done : .now, note: wrong.isEmpty ? nil : wrong.map(\.id).joined(separator: " · "), flag: !wrong.isEmpty)
        return [w] + steps
    }

    static func note(_ id: LoopStep.ID, _ b: Branch, _ pr: Pr?, _ st: Stand) -> String? {
        switch id {
        case .gates:
            switch b.gates {
            case .running: return "running"
            case .red: return b.redGates.isEmpty ? "red" : b.redGates.joined(separator: ", ")
            case .stale: return "stale"
            default: return "not run"
            }
        case .push: return b.pushed == .ahead ? "\(b.ahead) to push" : "\(b.commits) local"
        case .pr: return "open it"
        case .review: return pr?.review == "CHANGES_REQUESTED" ? "changes requested" : pr?.draft == true ? "draft" : "waiting"
        case .merged: return st.waiting.first?.label
        case .words: return nil
        }
    }

    /// The command a step in the way runs when a label picks it: the step's own next move.
    public static func command(_ step: LoopStep.ID) -> String? {
        switch step {
        case .gates, .push: "branch.push"
        case .pr, .merged: "branch.pr"
        case .review: "branch.open"
        case .words: "review.tab.commits"
        }
    }
}
