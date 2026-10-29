import CanopyCore
import SwiftUI

/// review/Conversation.tsx: the PR's body, then its timeline — reviews, top-level comments and the
/// conversations on the diff — oldest first, the second reader's "nobody flagged" list, and the way
/// to GitHub, where Phil submits his pending review. A pane ("conversation"): j/k walk the cards,
/// the thread under the cursor takes r, E, a, z, i, ret.
public struct ConversationPanel: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    let branchID: String

    public init(branchID: String) { self.branchID = branchID }

    static let stateWord = ["APPROVED": "approved these changes", "CHANGES_REQUESTED": "requested changes", "COMMENTED": "reviewed",
                            "DISMISSED": "had a review dismissed"]

    public var body: some View {
        if let c = app.store.view(Conv.self, branchID) {
            let items = Dictionary(ShipRows.timeline(app, branchID).map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
            let pending = Dictionary(ShipRows.localItems(app, branchID).map { ("p|\($0.key)", $0) }, uniquingKeysWith: { a, _ in a })
            VStack(alignment: .leading, spacing: 6) {
                PaneList(pane: ShipSeam.conversationPane, rows: ShipRows.conversation(app, branchID)) { key, on in
                    if key == "c|body" {
                        card(author: c.author, meta: "opened #\(c.number) · \(c.headRef) → \(c.base)", body: c.body.isEmpty ? "_No description._" : c.body)
                    } else if key.hasPrefix("t|") {
                        ThreadView(id: String(key.dropFirst(2)), selected: on, aside: true)
                    } else if key.hasPrefix("p|"), let it = pending[key] {
                        PendingView(item: it, selected: on)
                    } else if let it = items[key] {
                        switch it {
                        case .review(let r):
                            card(author: r.author, meta: "\(Self.stateWord[r.state] ?? r.state.lowercased()) · \(shipAgo(r.at))", body: r.body,
                                 tint: r.state == "APPROVED" ? theme.patina : r.state == "CHANGES_REQUESTED" ? theme.ember : theme.inkDim)
                        case .comment(let x):
                            card(author: x.author, meta: shipAgo(x.at), body: x.body)
                        case .thread: EmptyView()
                        }
                    }
                }
                if let u = c.unflagged, !u.items.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack { Text("second reader").foregroundStyle(theme.goldDeep); Text("what no one flagged").foregroundStyle(theme.inkFaint) }
                        ForEach(Array(u.items.enumerated()), id: \.offset) { _, x in Text("\(x.path):\(x.line) — \(x.why)").foregroundStyle(theme.inkDim) }
                    }
                    .padding(6).overlay(Rectangle().stroke(theme.rule, lineWidth: 1))
                }
                HStack(spacing: 8) {
                    if let n = c.pending?.count, n > 0 {
                        Text("\(n) comment\(n == 1 ? "" : "s") in your pending review —").foregroundStyle(theme.ink)
                    } else {
                        Text("no pending comments").foregroundStyle(theme.inkFaint)
                    }
                    KeyButton(title: "submit on GitHub", id: "review.finish", target: branchID, gold: true)
                    if (app.store.view(Draft.self, branchID)?.items ?? []).contains(where: { $0.state == .draft }) {
                        KeyButton(title: "send every draft", id: "review.send.all", target: branchID)
                    }
                    Spacer(minLength: 0)
                }
            }
            .font(Theme.mono(12))
            .padding(.horizontal, 16)
        } else {
            Text("no PR").font(Theme.mono(12)).foregroundStyle(theme.inkFaint).padding(.horizontal, 16)
        }
    }

    private func card(author: String, meta: String, body: String, tint: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(author).foregroundStyle(theme.goldLeaf)
                Text(meta).foregroundStyle(tint ?? theme.inkFaint)
            }
            if !body.isEmpty { MarkdownView(body) }
        }
    }
}
