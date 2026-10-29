import CanopyCore
import SwiftUI

/// Getting a branch out the door, on the review page: the ship strip (sync, gates, prep, push),
/// the conversation (PR, threads, the ledger of drafts), the words (description, outline, packet)
/// and the history. No surface of its own — its views are embedded by ReviewPage.
enum ShipArea: PageArea {
    static let name = "ship"
    static func install(_ app: AppModel) {}
}

/// review/Ship.tsx: the branch's way out — sync, gates, prep, push.
struct ShipStripView: View {
    @Environment(\.theme) private var theme
    let branchID: String

    var body: some View {
        Text("ship strip — area: ship · ports review/Ship.tsx, syncing.ts, gates.ts, ship.ts, commands/sync.ts")
            .font(Theme.mono(11)).foregroundStyle(theme.inkFaint).padding(.horizontal, 16)
    }
}

/// review/Conversation.tsx + Thread.tsx: the PR's conversation and the review threads.
struct ConversationPanel: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    let branchID: String

    var body: some View {
        let threads = app.store.list(CanopyCore.Thread.self).filter { "\($0.repo):\($0.branch)" == branchID }
        Text("conversation — \(app.store.view(Conv.self, branchID).map { "#\($0.number) \($0.title)" } ?? "no PR") · \(threads.count) threads — area: ship")
            .font(Theme.mono(11)).foregroundStyle(theme.inkFaint).padding(.horizontal, 16)
    }
}

/// Commits.tsx: the branch's history tab.
struct CommitsPanel: View {
    let branchID: String
    var body: some View { Text("history — area: ship · ports Commits.tsx") }
}
