import CanopyCore
import SwiftUI

/// The review page (/v2/b/<repo>/<branch>): the diff, its cursor stops, folds, the file tree, the
/// commits tab, code navigation. The Ship area's panels (ship strip, conversation, history) sit
/// inside it through the views in Pages/Ship — the seam between the two porters.
enum ReviewArea: PageArea {
    static let name = "review"

    static func install(_ app: AppModel) {
        app.addSurface(ReviewSurface())
    }
}

struct ReviewSurface: PlaceholderSurface {
    let surfaceID = "review"

    func view(_ app: AppModel, route: Route) -> AnyView { AnyView(ReviewPage(route: route, placeholder: placeholder(app, route: route))) }

    func placeholder(_ app: AppModel, route: Route) -> Placeholder {
        let b = route.branchID.flatMap { app.store.view(Branch.self, $0) }
        return Placeholder(
            title: b?.name ?? route.arg, area: "review",
            sources: ["review/Review.tsx", "review/page.ts", "review/diff.ts", "review/InlineDiff.tsx", "review/side.ts",
                      "review/inline.ts", "review/highlight.ts", "review/Overlays.tsx", "review/types.ts", "review/TypesPop.tsx",
                      "CodePane.tsx", "nav.ts", "commands/review.ts (diff, cursor, folds, viewed, lsp)"],
            notes: b.map { [$0.subject, "\($0.commits) commits · gates \($0.gates.rawValue) · \($0.pushed.rawValue)"] + $0.outline } ?? [])
    }

    func crumbs(_ app: AppModel, route: Route) -> [Crumb]? {
        guard case .review(let repo, let name, _) = route else { return nil }
        if let p = Route.integrationOf(name) {
            return [Crumb(app.store.view(Project.self, "\(repo):\(p)")?.name ?? p, command: "route.back"), Crumb("✦ the whole forest")]
        }
        let b = route.branchID.flatMap { app.store.view(Branch.self, $0) }
        let forest = b.flatMap { app.store.view(Project.self, $0.project) }?.name
        return (forest.map { [Crumb($0, command: "route.back")] } ?? []) + [Crumb(b?.name ?? name)]
    }
}
