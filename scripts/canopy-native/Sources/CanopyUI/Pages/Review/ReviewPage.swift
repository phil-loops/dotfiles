import CanopyCore
import SwiftUI

/// Placeholder for review/Review.tsx. Embeds the Ship area's panels so both porters can work on
/// the same page without touching each other's files.
struct ReviewPage: View {
    let route: Route
    let placeholder: Placeholder

    var body: some View {
        let id = route.branchID ?? ""
        VStack(alignment: .leading, spacing: 8) {
            ShipStripView(branchID: id)
            PlaceholderPage(placeholder)
            ConversationPanel(branchID: id)
        }
    }
}
