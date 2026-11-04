import CanopyCore
import Foundation
import Testing
@testable import CanopyUI

/// The motion rule every page shares: a key that can't move says why, at both ends of every list.
@MainActor @Suite struct MotionRulesTests {
    func app(_ route: Route) throws -> AppModel {
        var c = AppConfig()
        c.route = route
        let a = AppModel(config: c, port: 1, telemetry: false)
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../CanopyCoreTests/Fixtures/state.json")
        a.store.hydrate(try Snapshot.decode(Data(contentsOf: url)))
        return a
    }

    @Test(arguments: ["forests", "forest"])
    func everyMotionAtEitherEndMovesOrSaysWhy(_ page: String) throws {
        let route: Route = page == "forests" ? .forests : .forest(repo: "loops", project: "hankles-limited-label")
        var silent: [String] = []
        for end in ["top", "bottom"] {
            for k in ["j", "k", "g g", "G", "C-d", "C-u", "h", "l", "J", "K"] {
                let a = try app(route)
                a.cursorTo(end == "top" ? 0 : Int.max)
                let before = (a.selected, a.pane?.id, a.router.route)
                for part in k.split(separator: " ") { a.keys.handle(String(part)) }
                let after = (a.selected, a.pane?.id, a.router.route)
                if before == after && a.runner.note == nil && a.nav.shown.isEmpty { silent.append("\(k) at the \(end)") }
            }
        }
        #expect(silent.isEmpty, "\(page): did nothing and said nothing — \(silent.joined(separator: ", "))")
    }
}
