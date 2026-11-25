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
    setenv("SHOW_CLAUDE_SAY", (scratch as NSString).appendingPathComponent("claude-say-stub"), 1)
    setenv("SHOW_EVENTS", (scratch as NSString).appendingPathComponent("events.jsonl"), 1)
    setenv("SHOW_INBOX", (scratch as NSString).appendingPathComponent("inbox"), 1)
    setenv("SHOW_INBOX_DECK", (scratch as NSString).appendingPathComponent("inbox-deck.json"), 1)
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
        ["id": "a1", "group": "Ideas", "title": "First idea", "body": page + (1...80).map { "\n\nParagraph \($0): long enough to wrap onto a second line at the page's width, so the page scrolls well past one screen." }.joined()],
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
    let sayStub = (scratch as NSString).appendingPathComponent("claude-say-stub")
    try? "#!/bin/sh\n[ \"$1\" = --topic ] && [ \"$2\" = abcd1234 ] && echo notice-forest && exit 0\nexit 1\n".write(toFile: sayStub, atomically: true, encoding: .utf8)
    chmod(sayStub, 0o755)
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
    /// ⌘ and the workspace's own number, whatever order the rail is in.
    /// Presses the workspace's ⌘ number; a workspace without one (off the rail) is switched to directly.
    func switchKey(_ workspace: Workspace) {
        guard let number = Int(workspace.key) else { return app.switchTo(workspace) }
        command(workspace.key, code: [18, 19, 20, 21, 23, 22, 26][number - 1])
    }

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

        let newer = at("newer-deck.json")
        write(["title": "Newer", "chart": ["kind": "bars"], "sections": [
            ["id": "n1", "group": "G", "title": "One", "body": "x", "view": "board", "compare": ["columns": ["a"], "rows": [], "legend": "y"]],
        ]], newer)
        check("a deck's keys and choices this build doesn't know are named",
              unknownParts(ofDeckAt: newer) == ["chart", "sections[0].compare.legend", "view \"board\""], unknownParts(ofDeckAt: newer).joined(separator: ", "))
        check("decks this build knows name nothing", [alpha, beta, forest, live].allSatisfy { unknownParts(ofDeckAt: $0).isEmpty },
              [alpha, beta, forest, live].map { unknownParts(ofDeckAt: $0).joined(separator: ", ") }.joined(separator: " | "))

        check("Machine is canopy's machine page on ⌘\(Workspace.machine.key)",
              app.workspaces[.machine]?.canopy?.home == "/v2/machine" && app.workspaces[.canopy]?.canopy?.home == nil)
        for workspace in [Workspace.inbox, .learn] {
            let key = workspace.key
            switchKey(workspace)
            check("⌘\(key) switches to \(workspace.name)", app.active == workspace, "front is \(app.active.name)")
        }
        check("Forest, Review and Runs have no ⌘ number", [Workspace.forest, .review, .runs].allSatisfy { $0.key.isEmpty })
        check("Bench is ⌘6", Workspace.api.key == "6")
        let benchFile = (decksDirectory as NSString).appendingPathComponent("selftest-bench.json")
        try? #"{"mode": "bench", "title": "Replay", "sections": [], "bench": {"repo": "loops", "project": "some-forest", "steps": []}}"#
            .write(toFile: benchFile, atomically: true, encoding: .utf8)
        let benchPath = canonicalPath(benchFile)
        check("a bench document routes to the Bench workspace", Workspace.route(benchPath).workspace == .api)
        check("a bench is on the shelf under its forest", shelfEntry(benchPath)?.topic == "some-forest" && shelfEntry(benchPath)?.title == "Replay")
        app.openPath(benchPath)
        let bench = app.workspaces[.api]
        check("opening a bench brings Bench forward on it", app.active == .api && bench?.currentBench?.head.canopyRoute == "/v2/p/loops/some-forest",
              "front is \(app.active.name), open \(bench?.current ?? "nothing")")
        check("the open bench titles the window", bench?.documentTitle == "Replay" && bench?.subtitle == "some-forest")
        bench?.showConsole()
        check("⌘⇧B closes the bench and leaves the console", bench?.current == nil && bench?.currentBench == nil)
        try? FileManager.default.removeItem(atPath: benchFile)
        // the finder steps below start in Review, which has no key now
        app.switchTo(.review)

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
        for _ in 0..<3 {
            tab()
            order.append(focusName)
        }
        check("⇥ cycles list → detail → shelf → list", order == ["list", "detail", "shelf", "list"], order.joined(separator: " → "))
        check("the focused column is outlined", app.shell.focusOutline?.target != nil)
        tab(shift: true)
        check("⇧⇥ goes back to the shelf", focusName == "shelf", focusName)
        tab()

        let deck = front.currentDeck!
        check("a Review deck has no reply bar", deck.actionBar.isHidden)
        press("j", code: 38)
        check("j moves down the section list", deck.selectedSection?.key == "a2", deck.selectedSection?.key ?? "-")
        press("k", code: 40)
        check("k moves back up", deck.selectedSection?.key == "a1", deck.selectedSection?.key ?? "-")
        enter()
        check("↵ in the list opens the page", focusName == "detail", focusName)
        command("s", code: 1)
        check("⌘S signs nothing off in Review", signoff(alpha)["a1"]?.signed != true)
        escape()

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
        switchKey(.runs)
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

        switchKey(.review)
        app.openPath(beta)
        app.focus(front.shelf)
        backspace()
        check("⌫ on the shelf archives the deck", !FileManager.default.fileExists(atPath: beta)
              && FileManager.default.fileExists(atPath: (show as NSString).appendingPathComponent("archive/beta-design.json")))
        check("…and the previous deck comes back", front.current == alpha, front.current ?? "-")

        arrivals()
        fold()
        labelling()

        switchKey(.learn)
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

        if let controller = app.tutor, let question = controller.session?.rungs.first {
            switchKey(.review)
            controller.acceptDictation("one message", path: tutor, question: question, part: "a")
            check("background dictation stays on the original part", controller.drafts["r1"]?["a"] == "one message" && app.active == .review)
            controller.acceptDictation("the same ID", path: tutor, question: question, part: "b")
            check("a dictated prediction waits for confidence", loadAnswers(tutor).isEmpty)
            controller.choose(confidence: 1)
            controller.acceptDictation("after retry", path: tutor, question: question, part: "b")
            let answer = loadAnswers(tutor)["r1"]
            check("finishing a voice prediction preserves its parts and confidence",
                  answer?.parts == ["a": "one message", "b": "the same ID after retry"] && answer?.confidence == "medium")
            controller.acceptDictation("late transcript", path: tutor, question: question, part: "a")
            check("an answered question keeps late dictation as a draft", controller.composer.string == "draft question late transcript" && loadAnswers(tutor)["r1"]?.parts == answer?.parts)
            controller.composer.string = "draft question"
            controller.saveDrafts()
        }

        let listing = Data(#"[{"session_id":"aaa","pane":"%3","topic":"x"},{"session_id":"bbb","pane":"%12","topic":"y"}]"#.utf8)
        var wav = Data("RIFF\0\0\0\0WAVEfmt ".utf8) + Data(count: 20) + Data("data\0\0\0\0".utf8)
        for sample: Int16 in [0, 16_384, -16_384, 32_767] { wav += withUnsafeBytes(of: sample.littleEndian) { Data($0) } }
        check("the live preview reads samples from a WAV still being written",
              LearnTranscriber.tail(of: wav, seconds: 10) == [0, 0.5, -0.5, Float(32_767) / 32_768]
              && LearnTranscriber.tail(of: wav, seconds: 2.0 / 16_000) == [-0.5, Float(32_767) / 32_768])
        check("the menu bar keeps the end of what it heard, on a word boundary",
              LearnTranscriber.heard("short") == "short" && LearnTranscriber.heard("one two three four", width: 12) == "…three four")
        check("a dictate link names its tmux pane", PaneDictation.pane(of: URL(string: "canopy://dictate?pane=12")!) == "%12"
              && PaneDictation.pane(of: URL(string: "canopy://v2/b/loops/x?pane=12")!) == nil)
        check("pane dictation targets the session in that pane, and none when it holds none",
              PaneDictation.session(in: "%12", listing: listing)?.session_id == "bbb" && PaneDictation.session(in: "%7", listing: listing) == nil)

        switchKey(.review)
        scrolledPartway()
        app.workspaces[.canopy]?.canopy?.resume(at: Self.canopyPlace)
        let historyBefore = showEvents.state.current[.canopy]
        app.saveAll()
        check("saving canopy's spot leaves History alone", showEvents.state.current[.canopy] == historyBefore,
              "\(String(describing: showEvents.state.current[.canopy]))")
        prefs.synchronize()
        relaunchChild()
    }

    /// Scrolls Review's long section partway down and checks a reload keeps that character at the top; the relaunch checks it again.
    func scrolledPartway() {
        guard let deck = front.currentDeck else { return check("Review has a deck open to scroll", false) }
        let clip = deck.textScroll.contentView
        clip.scroll(to: NSPoint(x: 0, y: (deck.text.bounds.height - clip.bounds.height) * 0.4))
        deck.textScroll.reflectScrolledClipView(clip)
        let place = deck.place ?? "-"
        let anchor = place.components(separatedBy: "?at=").last.flatMap { Int($0) } ?? 0
        check("a deck's place names its section and the character at the top", place.hasPrefix(deck.path + "#a1?at=") && anchor > 0, place)
        deck.reload()
        check("reload keeps the character at the top", deck.place == place && clip.bounds.minY > 0, "\(place) → \(deck.place ?? "-")")
        prefs.set(place, forKey: Self.reviewPlaceKey)
    }

    /// ⌘[ walks back more than one document; `show <file>` while Show sits behind only lands it on the shelf, with its
    /// session's topic; a `--focus` request opens it. Leaves Review back on Alpha.
    func arrivals() {
        let alpha = at("alpha-plan.json"), gamma = at("gamma-notes.json"), delta = at("delta-notes.json")
        let quiet = at("epsilon-notes.json"), focused = at("zeta-notes.json")
        for (path, title) in [(gamma, "Gamma notes"), (delta, "Delta notes"), (quiet, "Epsilon notes"), (focused, "Zeta notes")] {
            write(["title": title, "replyTo": "abcd1234", "sections": [["id": "s1", "group": "G", "title": "Only", "body": "One."]]], path)
        }
        switchKey(.review)
        for path in [gamma, alpha, gamma, delta] { app.openPath(path) }
        var walked: [String] = []
        for _ in 0..<4 {
            command("[", code: 33)
            walked.append(front.current ?? "-")
        }
        check("⌘[ walks the whole back stack, revisits included", walked == [gamma, alpha, gamma, alpha],
              walked.map { ($0 as NSString).lastPathComponent }.joined(separator: " → "))

        switchKey(.forest)
        app.application(NSApp, open: [inbox(.document(quiet))])
        settle()
        let review = app.workspaces[.review]!
        let waiting = review.entries.filter { $0.state == .waiting }.sorted { $0.touched > $1.touched }
        check("a session's deck arrives: nothing switches or opens", app.active == .forest && review.current == alpha,
              "front \(app.active.name), Review open: \(review.current ?? "-")")
        check("…and lands at the top of Waiting on you", waiting.first?.path == quiet, waiting.map(\.title).joined(separator: ", "))
        check("…its inbox file is used up", ((try? FileManager.default.contentsOfDirectory(atPath: inboxDirectory)) ?? []).isEmpty)
        for _ in 0..<40 where review.entries.first(where: { $0.path == quiet })?.topic == nil { settle(0.1) }
        check("…labelled with its session's topic", review.entries.first { $0.path == quiet }?.topic == "notice-forest",
              review.entries.first { $0.path == quiet }?.topic ?? "no topic")

        app.application(NSApp, open: [inbox(.document(focused), intent: .showNow)])
        settle()
        check("a session's showNow request opens it in its workspace", app.active == .review && front.current == focused,
              "front \(app.active.name), open: \(front.current ?? "-")")
        command("[", code: 33)
        switchKey(.forest)
        app.application(NSApp, open: [URL(fileURLWithPath: focused)])
        settle()
        check("a file Phil opens himself comes forward", app.active == .review && front.current == focused,
              "front \(app.active.name), open: \(front.current ?? "-")")

        app.application(NSApp, open: [inbox(.canopy("/v2/p/loops/zeta-forest"))])
        settle()
        check("a session's canopy page waits instead of switching", app.active == .review && showEvents.state.waiting.contains(.canopy("/v2/p/loops/zeta-forest")),
              "front \(app.active.name), waiting \(showEvents.state.waiting.map(\.key))")
        switchKey(.canopy)
        check("Canopy stays where it was: the page still waits", showEvents.state.waiting.contains(.canopy("/v2/p/loops/zeta-forest")))
        switchKey(.review)

        command("y", code: 16)
        let history = app.shell.finder?.matches ?? []
        check("⌘Y opens History, newest first", history.first?.path == "canopy:/v2/p/loops/zeta-forest" && history.first?.title == "Forest zeta-forest",
              history.prefix(3).map { "\($0.title) (\($0.progress))" }.joined(separator: ", "))
        check("…with what was opened as well as what arrived", history.contains { $0.path == focused && $0.state == .done }
              && history.contains { $0.path == quiet && $0.state == .waiting })
        type("epsilon")
        enter()
        check("↵ on a History row opens it, and it stops waiting", app.active == .review && front.current == quiet && app.shell.finder == nil
              && !showEvents.state.waiting.contains(.document(quiet)), "front \(app.active.name), open: \(front.current ?? "-")")
        check("the log replays to the state the app holds", ShowState.fold(showEvents.events) == showEvents.state)
        command("[", code: 33)
        command("[", code: 33)
    }

    /// A deck with `choices`: a digit records its choice and signs off, A takes the proposed one, both move to the next unsigned
    /// section; an old sign-off file without choices still loads, and a deck without choices keeps no bar and ignores the digits.
    /// Leaves Review back on Alpha.
    func labelling() {
        let alpha = at("alpha-plan.json"), labels = at("label-pages.json")
        write(["title": "Label pages", "choices": [["key": "1", "label": "impersonation"], ["key": "2", "label": "fine"], ["key": "3", "label": "unsure"]],
               "sections": [
                   ["id": "p1", "group": "Pages", "title": "Page one", "body": "One.", "proposed": "2"],
                   ["id": "p2", "group": "Pages", "title": "Page two", "body": "Two.", "proposed": "1"],
                   ["id": "p3", "group": "Pages", "title": "Page three", "body": "Three."],
                   ["id": "p4", "group": "Pages", "title": "Page four", "body": "Four.", "proposed": "3"],
               ]], labels)
        write(["p3": ["signed": true, "note": "old note", "at": "2026-11-01T00:00:00Z"]], (labels as NSString).deletingPathExtension + ".signoff.json")
        check("choices and proposed are keys this build knows", unknownParts(ofDeckAt: labels).isEmpty, unknownParts(ofDeckAt: labels).joined(separator: ", "))
        switchKey(.review)
        app.openPath(labels)
        settle()
        guard let deck = front.currentDeck, deck.path == labels else { return check("the labelling deck opens", false, front.current ?? "-") }
        let plainStore = SignOffStore(deckPath: (scratch as NSString).appendingPathComponent("plain.json"))
        plainStore.update("s1") { $0.signed = true }
        check("a sign-off written without a choice has no choice key", (try? String(contentsOf: plainStore.url, encoding: .utf8))?.contains("choice") == false)
        check("an old sign-off file without choices loads", deck.store.entries["p3"]?.note == "old note" && deck.store.entries["p3"]?.choice == nil)
        check("a labelling deck shows its choices and the sign-off bar", !deck.choiceBar.isHidden && !deck.actionBar.isHidden
              && deck.choiceBar.arrangedSubviews.compactMap { ($0 as? NSButton)?.identifier?.rawValue } == ["1", "2", "3"])
        deck.select(section: "p1")
        app.focus(deck.text)
        press("1", code: 18)
        check("a choice key records the choice and signs off", signoff(labels)["p1"]?.choice == "1" && signoff(labels)["p1"]?.signed == true,
              "\(String(describing: signoff(labels)["p1"]))")
        check("…and moves to the next section not signed off", deck.selectedSection?.key == "p2", deck.selectedSection?.key ?? "-")
        press("a", code: 0)
        check("A records the proposed choice", signoff(labels)["p2"]?.choice == "1" && signoff(labels)["p2"]?.signed == true,
              "\(String(describing: signoff(labels)["p2"]))")
        check("…and skips the section already signed off", deck.selectedSection?.key == "p4", deck.selectedSection?.key ?? "-")
        check("…keeping the old section's note", signoff(labels)["p3"]?.note == "old note")
        press("9", code: 25)
        check("a key with no choice records nothing", signoff(labels)["p4"] == nil && deck.selectedSection?.key == "p4")
        app.focusComposer()
        type("2")
        check("a digit typed into the note stays text", deck.composer.string == "2" && signoff(labels)["p4"] == nil, deck.composer.string)
        escape()
        deck.composer.string = ""
        deck.composer.didChangeText()
        deck.select(section: "p1")
        let buttons = deck.choiceBar.arrangedSubviews.compactMap { $0 as? NSButton }
        check("the recorded choice shows pressed and the proposed one is marked", buttons.map(\.state) == [.on, .off, .off]
              && buttons[1].attributedTitle.string.hasSuffix("proposed") && !buttons[0].attributedTitle.string.hasSuffix("proposed"),
              buttons.map(\.attributedTitle.string).joined(separator: " | "))

        command("[", code: 33)
        guard let plain = front.currentDeck, plain.path == alpha else { return check("⌘[ goes back to Alpha", false, front.current ?? "-") }
        check("a deck without choices keeps no bar", plain.actionBar.isHidden && plain.choiceBar.isHidden)
        app.focus(plain.text)
        let before = signoff(alpha)
        press("1", code: 18)
        press("a", code: 0)
        check("…and the choice keys do nothing there", signoff(alpha).keys.sorted() == before.keys.sorted() && signoff(alpha)["a1"]?.choice == nil)
    }

    /// A launcher's request, written to the inbox the way `show` writes it.
    func inbox(_ target: Target, intent: ShowRequest.Intent = .deliver) -> URL {
        let file = (inboxDirectory as NSString).appendingPathComponent("\(UUID().uuidString).json")
        try? FileManager.default.createDirectory(atPath: inboxDirectory, withIntermediateDirectories: true)
        let request = ShowRequest(target: target, actor: .session, session: nil, intent: intent)
        try? JSONEncoder().encode(request).write(to: URL(fileURLWithPath: file))
        return URL(fileURLWithPath: file)
    }

    /// The fold alone, no window: back stacks, waiting, dismissal.
    func fold() {
        let a = Target.document("/a.json"), b = Target.document("/b.json"), c = Target.document("/c.json")
        func opened(_ t: Target, back: Bool? = nil) -> ShowEvent { ShowEvent(kind: .opened, target: t, workspace: .review, title: "", back: back) }
        let walk = ShowState.fold([opened(a), opened(b), opened(c), opened(b, back: true)])
        check("fold: ⌘[ steps down the back stack", walk.current[.review] == b && walk.back[.review] == [a], "\(walk.back[.review] ?? [])")
        let arrived = ShowState.fold([ShowEvent(kind: .arrived, target: c, workspace: .review, title: ""), opened(a)])
        check("fold: an arrival waits until it's opened", arrived.waiting == [c] && ShowState.fold([ShowEvent(kind: .arrived, target: c, workspace: .review, title: ""), opened(c)]).waiting.isEmpty)
        let dismissed = ShowState.fold([opened(a), opened(b), ShowEvent(kind: .dismissed, target: a, workspace: .review, title: "")])
        check("fold: a dismissed document leaves the back stack", dismissed.back[.review] == [] && dismissed.current[.review] == b)
        let canopy = ShowState.fold([opened(a), ShowEvent(kind: .opened, target: .canopy("/v2"), workspace: .canopy, title: "")])
        check("fold: canopy pages never enter a back stack", canopy.back[.canopy] ?? [] == [])
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
        let review = app.workspaces[.review]
        check("Review comes back scrolled to the same character", review?.place != nil && review?.place == prefs.string(forKey: Self.reviewPlaceKey)
              && (review?.currentDeck?.textScroll.contentView.bounds.minY ?? 0) > 0,
              "\(review?.place ?? "-") vs saved \(prefs.string(forKey: Self.reviewPlaceKey) ?? "-")")
        check("Learn keeps the composer draft", app.tutor?.composer.string == "draft question", app.tutor?.composer.string ?? "-")
        check("Canopy comes back on its page's file and line", app.workspaces[.canopy]?.canopy?.place == Self.canopyPlace,
              app.workspaces[.canopy]?.canopy?.place ?? "-")
    }

    static let canopyPlace = "/v2/b/loops/beta-branch?file=b.ts&line=6"
    /// Where the first half left Review, for the relaunch to compare against.
    static let reviewPlaceKey = "selftest.review-place"
}
