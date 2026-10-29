import CanopyCore
import SwiftUI

/// Helix's which-key (WhichKey.tsx): a half-typed prefix (space, g, C-w) opens a box in the corner
/// listing what can follow it here — the real key beside what it does, so pressing through it
/// rehearses the shortcut. Generic: its rows are whatever the registry binds under the prefix in the
/// live mode and scopes (`KeyEngine.whichKeyRows`), the narrowest scope's meaning winning. It never
/// takes focus.
struct WhichKeyView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        if !app.keys.pendingKeys.isEmpty {
            let rows = app.keys.whichKeyRows()
            VStack(alignment: .leading, spacing: 1) {
                Text(glyph(app.keys.pendingKeys)).foregroundStyle(theme.goldLeaf).padding(.bottom, 4)
                if rows.isEmpty {
                    Text("nothing here").foregroundStyle(theme.inkFaint)
                }
                ForEach(rows, id: \.key) { r in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(glyph(r.key)).foregroundStyle(theme.goldLeaf).frame(minWidth: 32, alignment: .leading)
                        Text(r.what).foregroundStyle(theme.inkDim)
                    }
                }
            }
            .font(Theme.mono(12))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(minWidth: 220, maxWidth: 420, alignment: .leading)
            .background(theme.vellumRaise)
            .overlay { Rectangle().stroke(theme.rule, lineWidth: 1) }
            .shadow(color: .black.opacity(0.4), radius: 16, y: 8)
            .allowsHitTesting(false)
        }
    }
}
