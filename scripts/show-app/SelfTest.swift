import AppKit

/// `show --selftest`: the app drives its own offscreen window with synthesized key events (through `NSApp.sendEvent`, in-process),
/// on fixtures in a scratch library, and exits non-zero if any step fails. `--selftest-relaunch <dir>` is its second half:
/// a fresh process on the same scratch state that checks each workspace came back on its document.
enum SelfTestMode {
    case run(String)
    case relaunch(String)

    init?(_ arguments: [String]) {
        if let flag = arguments.firstIndex(of: "--selftest-relaunch"), flag + 1 < arguments.count {
            self = .relaunch(arguments[flag + 1])
        } else if arguments.contains("--selftest") {
            let scratch = (NSTemporaryDirectory() as NSString).appendingPathComponent("show-selftest-\(ProcessInfo.processInfo.processIdentifier)")
            self = .run(canonicalPath(scratch))
        } else {
            return nil
        }
    }

    var scratch: String {
        switch self {
        case .run(let dir), .relaunch(let dir): return dir
        }
    }
}

var selfTest: SelfTestMode?
let selfTestSuite = "com.philbrockman.show.selftest"

/// Points every path Show writes at the scratch directory before anything reads them: the library, live-runs.json, prefs,
/// the learning graph, and a stub for `claude`.
func prepareSelfTest(_ mode: SelfTestMode) {
    setvbuf(stdout, nil, _IOLBF, 0)
    DispatchQueue.global().asyncAfter(deadline: .now() + 90) {
        print("✗ selftest timed out after 90s (a step is stuck, likely a modal or a run loop wait)")
        exit(2)
    }
    let scratch = mode.scratch
    let library = (scratch as NSString).appendingPathComponent("show")
    setenv("SHOW_DIR", library, 1)
    setenv("SHOW_LIVE_RUNS", (scratch as NSString).appendingPathComponent("live-runs.json"), 1)
    setenv("SHOW_CLAUDE", (scratch as NSString).appendingPathComponent("claude-stub"), 1)
    setenv("LEARNING_GRAPH", (scratch as NSString).appendingPathComponent("graph.json"), 1)
    setenv("LEARNING_MEMORY", "0", 1)
    if case .run = mode {
        UserDefaults.standard.removePersistentDomain(forName: selfTestSuite)
        try? FileManager.default.removeItem(atPath: scratch)
        writeSelfTestFixtures(scratch)
    }
    prefs = UserDefaults(suiteName: selfTestSuite) ?? .standard
}

private func write(_ object: Any, _ path: String) {
    try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted]).write(to: URL(fileURLWithPath: path))
}

func writeSelfTestFixtures(_ scratch: String) {
    let show = (scratch as NSString).appendingPathComponent("show")
    func at(_ name: String) -> String { (show as NSString).appendingPathComponent(name) }
    let page = "Prose with **bold**.\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n```\ncode\n```"
    write(["title": "Alpha plan", "sections": [
        ["id": "a1", "group": "Ideas", "title": "First idea", "body": page],
        ["id": "a2", "group": "Ideas", "title": "Second idea", "body": "Two."],
        ["id": "a3", "group": "Plan", "title": "Build order", "body": "Three."],
    ]], at("alpha-plan.json"))
    write(["title": "Beta design", "sections": [["id": "b1", "group": "Design", "title": "Only page", "body": "Short."]]], at("beta-design.json"))
    write(["title": "Notice forest", "mode": "forest", "project": "notice", "repo": "loops", "sections": [
        ["id": "story", "group": "Overview", "title": "Merge story", "body": "1. add-notice-query"],
        ["id": "add-notice-query", "group": "query", "title": "add notice query", "rank": 1, "body": page],
    ]], at("notice-branches.json"))
    write(["title": "Run seven", "mode": "live", "status": ["state": "running", "done": 3, "total": 9], "sections": [
        ["id": "v13::live", "group": "Live", "title": "msg-0102", "body": page],
    ]], at("run-7.json"))
    write(["mode": "tutor", "title": "SQS fixture", "stations": [["name": "In flight", "state": "current"]], "rungs": [[
        "id": "r1", "station": "In flight", "title": "One or two?", "situation": "A worker dies holding M.", "ask": "predict",
        "parts": [["id": "a", "ask": "How many?"], ["id": "b", "ask": "Why?"]],
    ]]], at("tutor/sqs-fixture.json"))
    let runDirectory = (scratch as NSString).appendingPathComponent("runs")
    write(["title": "Elsewhere run", "mode": "live", "status": ["state": "failed"], "sections": [["id": "x", "group": "G", "title": "x", "body": "x"]]],
          (runDirectory as NSString).appendingPathComponent("run-8.json"))
    write([["path": (runDirectory as NSString).appendingPathComponent("run-8.json"), "title": "Elsewhere run", "openedAt": "2026-10-29T00:00:00Z"]],
          (scratch as NSString).appendingPathComponent("live-runs.json"))
    let stub = (scratch as NSString).appendingPathComponent("claude-stub")
    try? "#!/bin/sh\nprintf '%s\\n' \"$PWD\" \"$@\" > \"$(dirname \"$0\")/claude-args.txt\"\n".write(toFile: stub, atomically: true, encoding: .utf8)
    chmod(stub, 0o755)
}

extension AppDelegate {
    func runSelfTest(_ mode: SelfTestMode) -> Int32 {
        let scratch = mode.scratch
        guard canonicalPath(decksDirectory).hasPrefix(scratch), let registry = liveRunsPath, registry.hasPrefix(scratch) else {
            print("✗ refusing to run: the library or live-runs.json points outside \(scratch)")
            return 70
        }
        window.setFrameOrigin(NSPoint(x: -30000, y: -30000))
        window.alphaValue = 0
        window.orderFrontRegardless()
        window.makeKey()
        let test = SelfTestDriver(app: self, scratch: scratch)
        switch mode {
        case .run: test.run()
        case .relaunch: test.relaunched()
        }
        print(test.failures == 0 ? "selftest: all \(test.steps) steps passed" : "selftest: \(test.failures) of \(test.steps) steps FAILED")
        if case .run = mode, test.failures == 0 {
            try? FileManager.default.removeItem(atPath: scratch)
            UserDefaults.standard.removePersistentDomain(forName: selfTestSuite)
        }
        return test.failures == 0 ? 0 : 1
    }
}

final class SelfTestDriver {
    let app: AppDelegate
    let scratch: String
    var steps = 0
    var failures = 0

    init(app: AppDelegate, scratch: String) {
        self.app = app
        self.scratch = scratch
    }

    var show: String { (scratch as NSString).appendingPathComponent("show") }
    func at(_ name: String) -> String { canonicalPath((show as NSString).appendingPathComponent(name)) }
    var window: NSWindow { app.window }
    var front: WorkspaceController { app.workspaces[app.active]! }

    func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        steps += 1
        if ok {
            print("✓ \(name)")
        } else {
            failures += 1
            print("✗ \(name)" + { let d = detail(); return d.isEmpty ? "" : " — \(d)" }())
        }
    }

    func settle(_ seconds: TimeInterval = 0.05) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// Sends one key through `NSApp.sendEvent`, as the window server would deliver it.
    func press(_ characters: String, code: UInt16 = 0, _ modifiers: NSEvent.ModifierFlags = []) {
        let ignoring = modifiers.contains(.shift) ? characters : characters.lowercased()
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, characters: characters,
                                           charactersIgnoringModifiers: ignoring, isARepeat: false, keyCode: code) else { return }
        NSApp.sendEvent(event)
        settle()
    }

    func type(_ text: String) {
        text.forEach { press(String($0), $0.isUppercase || $0 == "?" ? .shift : []) }
    }

    func tab(shift: Bool = false) { press(shift ? "\u{19}" : "\t", code: 48, shift ? .shift : []) }
    func enter() { press("\r", code: 36) }
    func escape() { press("\u{1b}", code: 53) }
    func backspace() { press("\u{7f}", code: 51) }
    func command(_ key: String, code: UInt16 = 0, shift: Bool = false) { press(key, code: code, shift ? [.command, .shift] : .command) }

    var focusName: String {
        let stops = app.focusStops
        guard let index = app.currentStop() else { return "none(\(window.firstResponder.map { String(describing: Swift.type(of: $0)) } ?? "nil"))" }
        let responder = stops[index].responder
        if responder === front.shelf { return "shelf" }
        if let deck = front.currentDeck {
            if responder === deck.table { return "list" }
            if responder === deck.composer { return "note" }
            if responder === deck.text || responder === deck.web { return "detail" }
        }
        if let tutor = front.tutor {
            if responder === tutor.composer { return "composer" }
            if responder === tutor.sidebar.table { return "stations" }
            if tutor.fields.contains(where: { $0 === responder }) { return "field" }
        }
        return "stop\(index)"
    }

    func signoff(_ deck: String) -> [String: SignOff] {
        let url = URL(fileURLWithPath: (deck as NSString).deletingPathExtension + ".signoff.json")
        return (try? JSONDecoder().decode([String: SignOff].self, from: Data(contentsOf: url))) ?? [:]
    }

    func run() {
        let alpha = at("alpha-plan.json"), beta = at("beta-design.json"), forest = at("notice-branches.json")
        let tutor = at("tutor/sqs-fixture.json"), live = at("run-7.json")
        for path in [forest, tutor, live, alpha] { app.openPath(path) }
        settle()
        check("each workspace opens its fixture",
              app.workspaces[.forest]?.current == forest && app.workspaces[.learn]?.current == tutor
                && app.workspaces[.runs]?.current == live && app.workspaces[.review]?.current == alpha,
              Workspace.allCases.map { "\($0): \(app.workspaces[$0]?.current ?? "-")" }.joined(separator: ", "))

        for (key, workspace) in [("1", Workspace.forest), ("3", .learn), ("4", .runs), ("2", .review)] {
            command(key, code: [18, 19, 20, 21][Int(key)! - 1])
            check("⌘\(key) switches to \(workspace.name)", app.active == workspace, "front is \(app.active.name)")
        }

        app.focus(front.currentDeck!.table)
        press("/", code: 44)
        check("/ opens the finder", app.shell.finder != nil)
        type("beta")
        check("typing filters the finder", app.shell.finder?.matches.first?.path == beta, app.shell.finder?.matches.map(\.title).joined(separator: ", ") ?? "no finder")
        enter()
        check("↵ opens the match", front.current == beta && app.shell.finder == nil, "open: \(front.current ?? "-")")
        command("[", code: 33)
        check("⌘[ goes back", front.current == alpha, "open: \(front.current ?? "-")")

        app.focus(front.currentDeck!.table)
        var order: [String] = [focusName]
        for _ in 0..<4 {
            tab()
            order.append(focusName)
        }
        check("⇥ cycles list → detail → note → shelf → list", order == ["list", "detail", "note", "shelf", "list"], order.joined(separator: " → "))
        check("the focused column is outlined", app.shell.focusOutline?.target != nil)
        tab(shift: true)
        check("⇧⇥ goes back to the shelf", focusName == "shelf", focusName)
        tab()

        let deck = front.currentDeck!
        press("j", code: 38)
        check("j moves down the section list", deck.selectedSection?.key == "a2", deck.selectedSection?.key ?? "-")
        press("k", code: 40)
        check("k moves back up", deck.selectedSection?.key == "a1", deck.selectedSection?.key ?? "-")
        enter()
        check("↵ in the list opens the page", focusName == "detail", focusName)

        press("n", code: 45)
        check("n jumps into the reply field", focusName == "note", focusName)
        let note = "Pushback: j k / ? n stay text"
        type(note)
        check("bare keys type into the reply", deck.composer.string == note, deck.composer.string)
        escape()
        check("⎋ leaves the reply for the list, text kept", focusName == "list" && deck.composer.string == note, "\(focusName), “\(deck.composer.string)”")
        command("s", code: 1)
        check("⌘S signs the section off", signoff(alpha)["a1"]?.signed == true)
        press("n", code: 45)
        type(" more")
        command("\r", code: 36)
        check("⌘↩ in the reply sends it", signoff(alpha)["a1"]?.note == note + " more" && deck.composer.string.isEmpty,
              "“\(signoff(alpha)["a1"]?.note ?? "-")”, field “\(deck.composer.string)”")
        escape()
        command("\r", code: 36)
        check("⌘↩ from the list submits", deck.submit.title.hasPrefix("Submitted"), deck.submit.title)

        press("?", code: 44, .shift)
        check("? opens the key sheet", app.shell.overlay is KeySheetOverlay)
        escape()
        check("⎋ closes the key sheet", app.shell.overlay == nil)

        command("n", code: 45)
        check("⌘N opens the New… prompt in Review", (app.shell.overlay as? NewPromptOverlay)?.workspace == .review)
        type("ducks")
        escape()
        command("n", code: 45)
        check("⎋ keeps the New… draft", (app.shell.overlay as? NewPromptOverlay)?.field.stringValue == "ducks",
              (app.shell.overlay as? NewPromptOverlay)?.field.stringValue ?? "no prompt")
        type(" in a row")
        enter()
        let requests = (try? FileManager.default.contentsOfDirectory(atPath: NewRequest.requestsDirectory).filter { $0.hasSuffix(".json") }) ?? []
        let request = requests.first.flatMap { try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: (NewRequest.requestsDirectory as NSString).appendingPathComponent($0)))) as? [String: String] }
        check("↵ writes the request file", request?["workspace"] == "review" && request?["text"] == "ducks in a row", "\(requests) \(request ?? [:])")
        let argsFile = (scratch as NSString).appendingPathComponent("claude-args.txt")
        for _ in 0..<40 where !FileManager.default.fileExists(atPath: argsFile) { settle(0.05) }
        let args = (try? String(contentsOfFile: argsFile, encoding: .utf8)) ?? ""
        check("…and runs the headless Claude in ~/.dotfiles with the show skill",
              args.hasPrefix(canonicalPath(("~/.dotfiles" as NSString).expandingTildeInPath)) && args.contains("-p\n") && args.contains("ducks in a row") && args.contains("skills/show/SKILL.md"),
              args)
        command("4", code: 21)
        command("n", code: 45)
        check("⌘N in Runs opens nothing", app.shell.overlay == nil)
        check("…and its menu item is off, with the reason", !app.isEnabled(KeyTable.binding("library.new-runs")!) && !app.isEnabled(KeyTable.binding("library.new")!))

        let runEight = canonicalPath((scratch as NSString).appendingPathComponent("runs/run-8.json"))
        check("the Runs shelf lists live-runs.json", front.entries.contains { $0.path == runEight && $0.state == .waiting })
        app.focus(front.shelf)
        if let row = (0..<front.shelf.numberOfRows).first(where: { front.shelf.view(atColumn: 0, row: $0, makeIfNecessary: true)?.toolTip == (runEight as NSString).abbreviatingWithTildeInPath }) {
            front.shelf.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        app.focus(front.shelf)
        backspace()
        check("⌫ on a listed run forgets it and leaves its file", FileManager.default.fileExists(atPath: runEight) && !registeredLiveRuns().contains(runEight),
              "registry: \(registeredLiveRuns())")

        command("2", code: 19)
        app.openPath(beta)
        app.focus(front.shelf)
        backspace()
        check("⌫ on the shelf archives the deck", !FileManager.default.fileExists(atPath: beta)
              && FileManager.default.fileExists(atPath: (show as NSString).appendingPathComponent("archive/beta-design.json")))
        check("…and the previous deck comes back", front.current == alpha, front.current ?? "-")

        command("3", code: 20)
        app.focus(front.shelf)
        var learnOrder: [String] = [focusName]
        for _ in 0..<4 {
            tab()
            learnOrder.append(focusName)
        }
        check("⇥ in Learn: shelf → stations → fields → composer", learnOrder == ["shelf", "stations", "field", "field", "composer"], learnOrder.joined(separator: " → "))
        type("draft question")
        escape()
        check("⎋ leaves the composer with its text", app.tutor?.composer.string == "draft question" && !app.isTyping, app.tutor?.composer.string ?? "-")

        command("2", code: 19)
        app.saveAll()
        prefs.synchronize()
        relaunchChild()
    }


    /// Starts a fresh Show on the same scratch library and prefs, which checks what it restored.
    func relaunchChild() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0])
        process.arguments = ["--selftest-relaunch", scratch]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            check("relaunch starts", false, "\(error)")
            return
        }
        let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        for line in text.split(separator: "\n") where line.hasPrefix("✓") || line.hasPrefix("✗") {
            print("  relaunch " + line)
            steps += 1
            if line.hasPrefix("✗") { failures += 1 }
        }
        check("relaunch exits cleanly", process.terminationStatus == 0, "exit \(process.terminationStatus)\n\(text)")
    }

    /// The relaunched half: no paths given, so everything on screen came from the saved state.
    func relaunched() {
        let expected: [Workspace: String] = [.forest: at("notice-branches.json"), .review: at("alpha-plan.json"),
                                             .learn: at("tutor/sqs-fixture.json"), .runs: at("run-7.json")]
        check("comes back on the workspace it left", app.active == .review, app.active.name)
        for workspace in Workspace.allCases {
            check("\(workspace.name) reopens its document", app.workspaces[workspace]?.current == expected[workspace],
                  app.workspaces[workspace]?.current ?? "nothing open")
        }
        check("Review keeps the selected section", app.workspaces[.review]?.currentDeck?.selectedSection?.key == "a1",
              app.workspaces[.review]?.currentDeck?.selectedSection?.key ?? "-")
        check("Learn keeps the composer draft", app.tutor?.composer.string == "draft question", app.tutor?.composer.string ?? "-")
    }
}
