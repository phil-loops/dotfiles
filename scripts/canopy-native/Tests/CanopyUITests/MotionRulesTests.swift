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

    /// Every page, by its route — the review page with no diff read yet (its motions hold, and say so),
    /// the machine page before it has taken stock, the wiki with its fixture pages, the tutors cold.
    static let pages: [String: Route] = [
        "forests": .forests, "forest": .forest(repo: "loops", project: "hankles-limited-label"),
        "review": .review(repo: "loops", branch: "add-hankles-limited-label"),
        "todo": .todo, "machine": .machine, "dashboard": .dashboard, "wiki": .wiki(slug: nil),
        "tutor": .tutor(session: nil), "keytutor": .keytutor(lesson: nil),
    ]

    @Test(arguments: ["forests", "forest", "review", "todo", "machine", "dashboard", "wiki", "tutor", "keytutor"])
    func everyMotionAtEitherEndMovesOrSaysWhy(_ page: String) throws {
        let route = Self.pages[page]!
        var silent: [String] = []
        for end in ["top", "bottom"] {
            for k in ["j", "k", "g g", "G", "C-d", "C-u", "h", "l", "J", "K"] {
                let a = try app(route)
                if case .wiki = route { a.state { WikiState() }.seed(try JSONDecoder().decode(PagesReply.self, from: Data(WikiFixture.pages.utf8))) }
                // the key tutor hands every key to its practice app: that is where a motion answers
                let inner: AppModel = { if case .keytutor = route { return KeyTutor.of(a).ensureSandbox() } else { return a } }()
                inner.cursorTo(end == "top" ? 0 : Int.max)
                let before = (inner.selected, inner.pane?.id, inner.router.route)
                for part in k.split(separator: " ") { a.keys.handle(String(part)) }
                let after = (inner.selected, inner.pane?.id, inner.router.route)
                if before == after && inner.runner.note == nil && inner.nav.shown.isEmpty { silent.append("\(k) at the \(end)") }
            }
        }
        #expect(silent.isEmpty, "\(page): did nothing and said nothing — \(silent.joined(separator: ", "))")
    }
}
