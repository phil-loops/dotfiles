import CanopyCore
import SwiftUI

/// The label layer's geometry (NAV.md §4.3): views say where their targets are, the shell keeps it
/// out of observation (it changes on every scroll) and reads it once when `g w` / `f` opens.
public extension View {
    /// This view is something the label layer can point at. `pane` is a `Pane.id` for a row (then
    /// `key` must be its row key, and picking it moves the cursor there and runs `ret`), or any group
    /// name for a free target ("tabs"), which needs `run`. PaneList rows wear it already.
    func labelTarget(pane: String, key: String, title: String = "", run: RouteTo? = nil) -> some View {
        modifier(LabelTargetModifier(pane: pane, key: key, title: title, run: run))
    }

    /// This view is the visible area of pane `id`: rows outside it get no label. PaneList wears it.
    func labelPane(_ id: String) -> some View { modifier(LabelPaneModifier(pane: id)) }
}

struct LabelTargetModifier: ViewModifier {
    @Environment(AppModel.self) private var app
    let pane: String
    let key: String
    let title: String
    let run: RouteTo?

    func body(content: Content) -> some View {
        content.background {
            GeometryReader { g in
                let rect = g.frame(in: .global)
                Color.clear
                    .onAppear { app.noteTarget(LabelTarget(pane: pane, key: key, rect: rect, title: title, run: run)) }
                    .onChange(of: rect) { _, r in app.noteTarget(LabelTarget(pane: pane, key: key, rect: r, title: title, run: run)) }
                    .onDisappear { app.dropTarget(pane: pane, key: key) }
            }
        }
    }
}

struct LabelPaneModifier: ViewModifier {
    @Environment(AppModel.self) private var app
    let pane: String

    func body(content: Content) -> some View {
        content.background {
            GeometryReader { g in
                let rect = g.frame(in: .global)
                Color.clear
                    .onAppear { app.notePaneFrame(pane, rect) }
                    .onChange(of: rect) { _, r in app.notePaneFrame(pane, r) }
                    .onDisappear { app.notePaneFrame(pane, nil) }
            }
        }
    }
}
