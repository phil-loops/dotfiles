import AppKit

/// `--tutor-check`: parse a session plus its answers and print what the Tutor space would show, without a window.
func tutorCheck(_ raw: String) -> Int32 {
    let path = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath).standardizedFileURL.path
    do {
        let session = try loadTutorSession(path)
        let sidecar = try readSidecar(path)
        let answers = sidecar.answers
        print("session: \(session.title)")
        print("replyTo: \(session.replyTo ?? "-")")
        print("agent: \(session.agent?.session ?? "-") (\(session.usesAgent ? "answers go to the headless tutor" : "answers go to replyTo via claude-say"))")
        print("thread: \(sidecar.messages.count) learner messages, \((session.notes ?? []).count) tutor notes")
        print("answers: \(answersURL(path).path)")
        print("answered: \(session.rungs.filter { answers[$0.id] != nil }.map(\.id).joined(separator: ", "))")
        if let rung = currentRung(session, answers) {
            print("current: \(rung.id) (\(rung.ask); parts \(rung.answerParts.map(\.id).joined(separator: ", ")); confidence \(rung.isPredict ? "required" : "optional"))")
        } else {
            print("current: none (waiting for Claude)")
        }
        for station in session.stations ?? [] {
            let marker = station.state == "done" ? "✓" : station.state == "current" ? "●" : "○"
            print("station: \(marker) \(station.state) \(station.name)")
        }
        for item in session.due ?? [] {
            print("due: \(item.concept)")
        }
        for rung in session.rungs {
            let rail = railItems(rung).map { item -> String in
                switch item {
                case .event(let event): return event.t
                case .part(let part): return "[\(part.id)@\(part.at ?? "")]"
                }
            }
            let reveal: String
            switch rung.reveal {
            case .none: reveal = "none"
            case .whole: reveal = "whole"
            case .byPart(let byPart): reveal = "parts " + byPart.keys.sorted().joined(separator: ",")
            }
            print("rung \(rung.id): rail \(rail.isEmpty ? "-" : rail.joined(separator: " → ")); below \(rung.answerParts.filter { $0.at == nil }.map(\.id).joined(separator: ",")); reveal \(reveal); verdicts \((rung.verdicts ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ","))")
        }
        return 0
    } catch {
        FileHandle.standardError.write("Show: \(path): \(error)\n".data(using: .utf8)!)
        return 65
    }
}

/// The appearance snapshots draw in: light, or dark with `SHOW_SNAPSHOT_APPEARANCE=dark`.
let snapshotAppearance = NSAppearance(named: ProcessInfo.processInfo.environment["SHOW_SNAPSHOT_APPEARANCE"] == "dark" ? .darkAqua : .aqua)

/// Writes a view as drawn into a PNG, in the snapshot appearance.
func writePNG(_ view: NSView, to file: String) {
    snapshotAppearance?.performAsCurrentDrawingAppearance {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: file))
    }
}

/// The whole window as drawn, with each visible list painted over its slot: an ancestor's capture leaves table rows out.
func writeComposite(_ root: NSView, to file: String) {
    snapshotAppearance?.performAsCurrentDrawingAppearance {
        guard let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { return }
        root.cacheDisplay(in: root.bounds, to: rep)
        func tables(in view: NSView) -> [NSTableView] {
            view.subviews.flatMap { sub -> [NSTableView] in
                if let table = sub as? NSTableView { return [table] }
                return tables(in: sub)
            }
        }
        guard let canvas = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: canvas)
        NSColor.windowBackgroundColor.setFill()
        root.bounds.fill()
        rep.draw(in: root.bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
        for table in tables(in: root) where !table.isHiddenOrHasHiddenAncestor {
            let visible = table.visibleRect
            let pixels = CGFloat(canvas.pixelsWide) / max(root.bounds.width, 1)
            guard visible.width > 0, visible.height > 0,
                  let part = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(visible.width * pixels), pixelsHigh: Int(visible.height * pixels),
                                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                              colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { continue }
            part.size = visible.size
            table.cacheDisplay(in: visible, to: part)
            let slot = table.convert(visible, to: root)
            part.draw(in: slot, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
        }
        NSGraphicsContext.restoreGraphicsState()
        try? canvas.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: file))
    }
}

extension AppDelegate {
    /// Renders the window offscreen: the whole window (`out`), the rail (`-rail`), and the open document's parts, which run taller than the window.
    func snapshot(to output: String) {
        if let named = ProcessInfo.processInfo.environment["SHOW_SNAPSHOT_WORKSPACE"], let workspace = Workspace(rawValue: named) {
            switchTo(workspace)
        }
        window.appearance = snapshotAppearance
        let environment = ProcessInfo.processInfo.environment
        if environment["SHOW_SNAPSHOT_BACK"] != nil {
            workspaces[active]?.goBack()
        }
        if let archived = environment["SHOW_SNAPSHOT_ARCHIVE"], let entry = workspaces[active]?.entries.first(where: { $0.path == canonicalPath(archived) }) {
            workspaces[active]?.archive(entry)
        }
        refreshLibrary(force: true)
        if let query = environment["SHOW_SNAPSHOT_FINDER"] {
            showFinder(nil)
            shell.finder?.search(query)
            print("finder \"\(query)\": " + (shell.finder?.matches.map(\.title).joined(separator: " | ") ?? "-"))
        }
        let controller = workspaces[active]
        if let key = ProcessInfo.processInfo.environment["SHOW_SNAPSHOT_SECTION"] {
            controller?.currentDeck?.select(section: key)
        }
        window.layoutIfNeeded()
        if let keys = environment["SHOW_SNAPSHOT_KEYS"] {
            controller?.currentDeck?.live.typeSnapshotKeys(keys)
        }
        shell.view.layoutSubtreeIfNeeded()
        controller?.currentDeck?.prepareSnapshot()
        shell.view.layoutSubtreeIfNeeded()
        controller?.currentDeck?.table.layoutSubtreeIfNeeded()
        if environment["SHOW_SNAPSHOT_CANOPY"] != nil {
            openInCanopy(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(1))
            print("status: \(controller?.statusLabel.stringValue ?? "-")")
        }
        let stem = (output as NSString).deletingPathExtension
        writeComposite(shell.view, to: output)
        writePNG(shell.rail, to: stem + "-rail.png")
        if let controller {
            controller.shelf.layoutSubtreeIfNeeded()
            writePNG(controller.shelf, to: stem + "-shelf.png")
            print("shelf: " + controller.entries.map { "\($0.state.mark) \($0.title)" }.joined(separator: " | ") + " · back: \(controller.back.map { ($0 as NSString).lastPathComponent })")
        }
        if let deck = controller?.currentDeck {
            writePNG(deck.table, to: stem + "-sidebar.png")
            deck.text.sizeToFit()
            writePNG(deck.text, to: stem + "-detail.png")
        }
        if active == .learn, let tutor {
            tutor.snapshotWorksheet(to: stem + "-worksheet.png")
        }
        print("workspace: \(active.rawValue) · title: \(controller?.documentTitle ?? "-") · subtitle: \(controller?.subtitle ?? "-")")
    }
}

/// `--check-routing`: print which workspace a file opens in, and why.
func checkRouting(_ raw: String) -> Int32 {
    let path = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath).standardizedFileURL.path
    guard FileManager.default.fileExists(atPath: path) else {
        FileHandle.standardError.write("Show: no such file: \(path)\n".data(using: .utf8)!)
        return 66
    }
    let route = Workspace.route(path)
    print("workspace: \(route.workspace.rawValue) (⌘\(route.workspace.key), by \(route.reason))")
    if let entry = shelfEntry(path) {
        print("shelf: \(entry.state) · \(entry.title) · \(entry.progress)")
    } else {
        print("shelf: unreadable as a \(route.workspace.name) document")
    }
    guard route.workspace == .forest, let deck = try? loadDeck(path) else { return 0 }
    let order = ForestOrder(deck)
    print("forest: project \(deck.project ?? "-") · repo \(deck.repo ?? "-")")
    print("overview:")
    for i in order.overview {
        print("     \(deck.sections[i].key)  —  \(deck.sections[i].title)")
    }
    print("merge order:")
    for branch in order.branches {
        let section = deck.sections[branch.index]
        let indent = String(repeating: "  ", count: branch.depth)
        print("  \(String(format: "%2d", branch.number))  \(indent)\(section.key)  (rank \(section.rank ?? 0), parent \(section.parent ?? "-"))")
    }
    if let first = order.branches.first, let command = canopyCommand(deck, deck.sections[first.index]) {
        print("⌘⇧O on \(deck.sections[first.index].key): \((command[0] as NSString).abbreviatingWithTildeInPath) \(command[1])")
    }
    return 0
}
