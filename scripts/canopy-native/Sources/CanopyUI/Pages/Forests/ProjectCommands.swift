import CanopyCore
import Foundation

/// commands/project.ts: moving a forest between focus, the workbench and the archive
/// (POST /project-state), ordering the focus lane (POST /focus — v2's drag is C-k / C-j here),
/// opening a forest into its spine, the forest page's faces and words, the ready filter, launch.
@MainActor
enum ProjectCommands {
    static let label: [ProjectState: String] = [.focus: "focus", .workbench: "the workbench", .archive: "the archive"]
    /// Archive is putting it away; focus and the workbench are this page's own (`, f` / `, w`).
    static let key: [ProjectState: (verb: Verb?, leader: LocalKey?)] = [.focus: (nil, LocalKey(",f")), .workbench: (nil, LocalKey(",w")), .archive: (.putAway, nil)]
    static let v1Key: [ProjectState: String] = [.focus: "f", .workbench: "w", .archive: "x"]

    static func install(_ app: AppModel) {
        unowned let app = app
        let r = app.registry
        let m = app.forestModel
        let s = app.store
        func exists(_ id: String?) -> Bool { id.flatMap { s.view(Project.self, $0) } != nil }

        func moveTo(_ state: ProjectState) -> (String, Any?) throws -> Write? {
            { id, _ in
                guard let p = s.view(Project.self, id), p.state != state else { return nil }
                let top = max(0, s.list(Project.self).filter { $0.state == .focus }.map { $0.rank ?? 0 }.max() ?? 0)
                let from = p.state
                return Write(
                    ops: [Op(type: .project, id: id, fields: ["state": .string(state.rawValue), "rank": state == .focus ? .number(Double(top + 1)) : .null])],
                    path: "/project-state",
                    body: ["repo": .string(p.repo), "project": .string(p.name), "state": .string(state.rawValue)],
                    settled: { s.table(Project.self)[id]?.state == state },
                    said: state == .archive ? "archived \(p.name) · u undoes" : from == .archive ? "restored \(p.name)" : nil,
                    failed: "couldn't move \(p.name) to \(label[state]!)",
                    inverse: { _ in Inverse(id: "project.\(from.rawValue)", target: id) })
            }
        }

        for state in [ProjectState.focus, .workbench, .archive] {
            r.register(Command(
                id: "project.\(state.rawValue)", title: "Move to \(label[state]!)", scope: .project, budget: .configWrite,
                verb: key[state]!.verb, leader: key[state]!.leader, label: state == .workbench ? "bench" : state.rawValue, v1: ["key:\(v1Key[state]!)"],
                available: { id in exists(id) && s.view(Project.self, id!)!.state != state },
                write: moveTo(state)))
        }
        r.register(Command(
            id: "project.restore", title: "Restore from the archive", scope: .project, budget: .configWrite,
            available: { id in exists(id) && s.view(Project.self, id!)!.state == .archive },
            write: moveTo(.workbench)))

        // ── the whole forest at once: does it merge, read it ──

        r.register(Command(
            id: "forest.integrate", title: "Check the whole forest merges onto main", scope: .project, label: "merges?",
            available: { m.integratable($0) },
            local: { id, _ in
                guard let id else { return }
                Task { await m.checkIntegration(id, again: true) }
            }))
        r.register(Command(
            id: "forest.integration", title: "Read the whole forest's diff against main", scope: .project, leader: LocalKey(",i"), label: "whole diff",
            available: { m.integratable($0) },
            local: { [unowned app] id, _ in
                guard let p = id.flatMap({ s.view(Project.self, $0) }) else { return }
                app.go(.review(repo: p.repo, branch: Route.integrationRef(p.name)))
            }))

        // ── the focus lane's order ──

        func focusIDs() -> [String] { m.projects().focus.map(\.id) }
        func inFocus(_ id: String?) -> Bool { id.flatMap { s.view(Project.self, $0) }?.state == .focus }

        /// Rewrite the lane's ranks 1..N with `id` at position `to`.
        func reorder(_ id: String, _ to: Int) -> Write? {
            var order = focusIDs()
            guard let from = order.firstIndex(of: id) else { return nil }
            let to = max(0, min(order.count - 1, to))
            if from == to { return nil }
            order.insert(order.remove(at: from), at: to)
            app.setCursor(RowKey.project(id))
            let name = s.view(Project.self, id)?.name ?? id
            let final = order
            return Write(
                ops: final.enumerated().map { i, pid in Op(type: .project, id: pid, fields: ["rank": .number(Double(i + 1))]) },
                path: "/focus",
                body: ["order": .array(final.compactMap { pid in
                    s.view(Project.self, pid).map { JSONValue.object(["repo": .string($0.repo), "project": .string($0.name)]) }
                })],
                settled: { final.enumerated().allSatisfy { i, pid in s.table(Project.self)[pid]?.rank == i + 1 } },
                failed: "couldn't reorder \(name)",
                inverse: { _ in Inverse(id: "focus.move", target: id, arg: from) })
        }

        r.register(Command(
            id: "focus.up", title: "Move up the focus lane", scope: .project, budget: .configWrite, verb: .moveUp,
            label: "move", pair: "focus.down", available: inFocus,
            write: { id, _ in reorder(id, (focusIDs().firstIndex(of: id) ?? 0) - 1) }))
        r.register(Command(
            id: "focus.down", title: "Move down the focus lane", scope: .project, budget: .configWrite, verb: .moveDown,
            label: "move", available: inFocus,
            write: { id, _ in reorder(id, (focusIDs().firstIndex(of: id) ?? 0) + 1) }))
        // v2's drop target and the reorder's undo: reached only with a place to put it
        r.register(Command(
            id: "focus.move", title: "Put a forest at a place in the focus lane", scope: .project, budget: .configWrite,
            needsArg: true, quiet: true, available: inFocus,
            write: { id, to in (to as? Int).flatMap { reorder(id, $0) } }))

        // ── opening a forest into its spine ──

        func hasBranches(_ id: String?) -> Bool { !(m.forest(id)?.branches.isEmpty ?? true) }

        r.register(Command(
            id: "forest.expand", title: "Show the forest's branches (open again: its page)", scope: .project, verb: .main, label: "open",
            available: { [unowned app] id in exists(id) && app.router.surface.id == "forests" },
            local: { [unowned app] id, _ in
                guard let id else { return }
                // the zoom ladder (NAV.md §4.1): a folded forest opens inline, an open one goes in to its page
                if hasBranches(id) && !m.expanded.contains(id) && !m.readyOnly { m.expanded.insert(id) }
                else { app.runner.dispatch("forest.page", via: .key, target: id) }
            }))
        r.register(Command(
            id: "forest.collapse", title: "Hide the forest's branches", scope: .project, verb: .out, label: "fold",
            available: { id in id.map { m.expanded.contains($0) } == true && !m.readyOnly },
            local: { [unowned app] id, _ in
                guard let id else { return }
                app.setCursor(RowKey.project(id))
                m.armed = nil
                m.expanded.remove(id)
                if m.launching == id { m.launching = nil }
            }))
        r.register(Command(
            id: "forest.toggle", title: "Open or fold the forest", scope: .project, quiet: true,
            available: { hasBranches($0) && !m.readyOnly },
            local: { id, _ in
                guard let id else { return }
                if m.expanded.contains(id) {
                    if m.launching == id { m.launching = nil }
                    m.expanded.remove(id)
                } else { m.expanded.insert(id) }
            }))

        // ↵: the selected row's one primary action
        r.register(Command(
            id: "row.primary", title: "Do the row's thing", scope: .row, verb: .main, label: "go", quiet: true,
            route: { [unowned app] row in ForestNav.primary(for: row ?? app.selected, app) }))

        r.register(Command(
            id: "forest.page", title: "Open the forest's page", scope: .project, available: exists,
            local: { [unowned app] id, _ in
                guard let p = id.flatMap({ s.view(Project.self, $0) }) else { throw Refusal("that forest is gone") }
                app.go(.forest(repo: p.repo, project: p.name))
                app.setCursor(nil)
            }))
        r.register(Command(
            id: "forest.words", title: "Show the branch's commits in full", scope: .branch, verb: .words, label: "words",
            available: { [unowned app] id in app.router.surface.id == "forest" && id != nil },
            local: { id, _ in if let id { m.wordsOpen.formSymmetricDifference([id]) } }))
        r.register(Command(
            id: "forest.face", title: "Switch between the story and the branches", scope: .forest, verb: .face, label: "story",
            local: { [unowned app] _, _ in
                m.face = m.face == .story ? .branches : .story
                app.setCursor(nil)
            }))
        r.register(Command(
            id: "story.why", title: "Show why a landed chapter happened", scope: .forest, verb: .words, label: "why",
            available: { [unowned app] _ in m.face == .story && app.selected?.hasPrefix("d:") == true },
            local: { [unowned app] _, arg in
                guard let k = (arg as? String) ?? app.selected else { return }
                m.wordsOpen.formSymmetricDifference([k])
            }))

        /// The forest page's branches that wait on Phil (push, open the PR, merge), in merge order.
        func readyHere() -> [BranchView] { m.forest(m.pageProject)?.ready ?? [] }
        r.register(Command(
            id: "forest.next.ready", title: "Go to the next branch ready for you", scope: .forest, leader: LocalKey(",n"), label: "next ready",
            recordsJump: true,
            available: { _ in m.face == .branches && !readyHere().isEmpty },
            local: { [unowned app] _, _ in
                let rs = readyHere()
                let at = rs.firstIndex { RowKey.branch($0.b.id) == app.selected } ?? -1
                app.setCursor(RowKey.branch(rs[(at + 1) % rs.count].b.id))
            }))
        r.register(Command(
            id: "forest.words.all", title: "Show or hide every branch's commits in full", scope: .forest, leader: LocalKey(",e"), label: "all words",
            available: { _ in m.face == .branches && m.pageProject != nil },
            local: { _, _ in
                let ids = (m.forest(m.pageProject)?.branches ?? []).map(\.b.id)
                if ids.allSatisfy(m.wordsOpen.contains) { m.wordsOpen.subtract(ids) } else { m.wordsOpen.formUnion(ids) }
            }))
        r.register(Command(
            id: "forest.leave", title: "Go back to Forests", scope: .forest, verb: .out, label: "back",
            local: { [unowned app] _, _ in
                // `-` is deterministic (NAV.md §4.1): Forests, with the cursor on this forest
                let pid = m.pageProject
                if let pid, s.view(Project.self, pid)?.state == .archive || m.shelved.contains(pid) { m.showArchive = true }
                app.go(.forests)
                if let pid { app.setCursor(RowKey.project(pid)) }
            }))

        r.register(Command(
            id: "ready.toggle", title: "Show only what's ready for you", scope: .forests, leader: LocalKey(",r"), label: "ready", v1: ["nav:outbox"],
            local: { _, _ in
                m.armed = nil
                m.readyOnly.toggle()
            }))
        r.register(Command(
            id: "archive.toggle", title: "Show or hide the archive", scope: .forests, leader: LocalKey(",a"), label: "archive",
            available: { _ in !m.readyOnly },
            local: { _, _ in m.showArchive.toggle() }))
        r.register(Command(
            id: "forest.launch", title: "Launch the whole forest", scope: .project, leader: LocalKey(",l"), label: "launch", v1: ["launch"],
            available: { id in !(m.forest(id)?.unopened.isEmpty ?? true) },
            local: { [unowned app] id, _ in
                guard let id, let first = m.forest(id)?.unopened.first else { return }
                m.readyOnly = false
                m.expanded.insert(id)
                m.launching = id
                app.setCursor(RowKey.branch(first.b.id))
            }))
    }
}
