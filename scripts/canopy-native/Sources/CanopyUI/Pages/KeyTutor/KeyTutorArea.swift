import CanopyCore
import SwiftUI

/// The keytutor (`/v2/keytutor`, `:keytutor [lesson]`): a vimtutor-style walkthrough of the keys,
/// learned by doing in a practice app. Not the Tutor page (the Socratic code tutor).
///
/// Its chrome is modal too: while the page is up every key goes to the practice app, where the
/// keytutor's own keys sit under the leader (`, k …`, the `practice` scope) and on `:`; the recap
/// between lessons is a layer whose keys are verbs (`main`, `next`). esc that cancels nothing in the
/// practice app leaves, back to where you were.
enum KeyTutorArea: PageArea {
    static let name = "keytutor"

    static func install(_ app: AppModel) {
        app.addSurface(KeyTutorSurface())
        app.registry.addScopes([.practice], to: "keytutor")
        app.keys.nested = { [weak app] in
            guard let app, app.router.route.surfaceID == "keytutor" else { return nil }
            let t = KeyTutor.of(app)
            return t.host == nil ? t.ensureSandbox().keys : nil
        }
        app.keys.afterNested = { [weak app] key, took in
            guard let app else { return }
            KeyTutor.of(app).observe(key, took: took)
        }
        app.dumpExtras["keytutor"] = { [weak app] in app.map { KeyTutor.of($0).dump() } ?? .null }
        install(commands: app)
    }

    /// The tutor that runs things from `app`: its own, or — in a practice app — the one running it.
    @MainActor static func tutor(_ app: AppModel) -> KeyTutor {
        let t = KeyTutor.of(app)
        return t.host ?? t
    }

    private static func install(commands app: AppModel) {
        let r = app.registry
        r.register(Command(id: "keytutor", title: "Learn the keys by doing them — :keytutor <lesson> jumps to one", scope: .global, label: "keytutor",
                           local: { [weak app] _, arg in
                               guard let app else { return }
                               try tutor(app).open(arg as? String)
                           }))
        let chrome: [(String, String, String, (KeyTutor) throws -> Void)] = [
            ("keytutor.skip", "Skip this step", ",k s", { $0.skip() }),
            ("keytutor.next", "Next lesson", ",k n", { t in
                guard t.lessonIndex + 1 < KeyTutor.lessons.count else { throw Refusal("that's the last lesson") }
                t.go(lesson: t.lessonIndex + 1)
            }),
            ("keytutor.prev", "Previous lesson", ",k p", { t in
                guard t.lessonIndex > 0 else { throw Refusal("that's the first lesson") }
                t.go(lesson: t.lessonIndex - 1)
            }),
            ("keytutor.restart", "Start this lesson over", ",k r", { t in t.go(lesson: t.lessonIndex) }),
            ("keytutor.leave", "Leave the keytutor", ",k q", { $0.leave() }),
        ]
        for (id, title, key, run) in chrome {
            r.register(Command(id: id, title: title, scope: .practice, leader: LocalKey(key), label: String(title.split(separator: " ").first ?? ""),
                               local: { [weak app] _, _ in
                                   guard let app else { return }
                                   try run(tutor(app))
                               }))
        }
        r.register(Command(id: "keytutor.lessons", title: "Pick a lesson", scope: .practice, leader: LocalKey(",k l"), label: "lessons",
                           local: { [weak app] _, _ in
                               guard let app else { return }
                               let t = tutor(app)
                               app.nav.pick("keytutor lessons", KeyTutor.lessons.map { l in
                                   PickItem(label: l.title, text: "\(t.done.contains(l.id) ? "✓ " : "")\(l.id) · \(l.teaches.count) steps")
                               }) { i in t.go(lesson: i) }
                           }))
        // the recap's keys: the keytutor reads the verb itself (KeyTutor.observe); this only binds them
        r.register(Command(id: "keytutor.continue", title: "On to the next lesson", scope: .practice, verbs: [.main, .next],
                           modes: [.keytutorRecap], quiet: true, local: { _, _ in }))
    }
}

struct KeyTutorSurface: SurfaceProvider {
    let surfaceID = "keytutor"

    func view(_ app: AppModel, route: Route) -> AnyView { AnyView(KeyTutorPage()) }

    func rows(_ app: AppModel) -> [String] { KeyTutor.lessons.map { "k:\($0.id)" } }

    func panes(_ app: AppModel) -> [Pane] { [Pane(id: "lessons", title: "lessons", rows: rows(app))] }

    func title(for row: String, _ app: AppModel) -> String? {
        RowKey.id(row, "k").flatMap { id in KeyTutor.lessons.first { $0.id == id }?.title }
    }

    func crumbs(_ app: AppModel, route: Route) -> [Crumb]? { [Crumb("keytutor")] }
}
