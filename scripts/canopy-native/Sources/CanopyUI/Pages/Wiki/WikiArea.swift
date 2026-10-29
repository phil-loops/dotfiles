import CanopyCore
import SwiftUI

/// The wiki (/v2/wiki[/<slug>]): the page list, a page's markdown, citations to source lines.
enum WikiArea: PageArea {
    static let name = "wiki"
    static func install(_ app: AppModel) { app.addSurface(WikiSurface()) }
}

struct WikiSurface: PlaceholderSurface {
    let surfaceID = "wiki"
    func placeholder(_ app: AppModel, route: Route) -> Placeholder {
        Placeholder(title: "Wiki", area: "wiki", sources: ["Wiki.tsx", "wikiread.ts", "wikitext.ts", "review/markdown.ts", "commands/wiki.ts"],
                    notes: ["page: \(route.arg.isEmpty ? "the first" : route.arg)"])
    }
}
