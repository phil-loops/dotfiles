// Show — one native window with four workspaces on a rail: Forest (⌘1), Review (⌘2), Learn (⌘3), Runs (⌘4).
// A file goes to the workspace its optional "workspace" key names, otherwise to the one its "mode" implies (forest, deck, tutor, live).
// Decks: { "title", "subtitle"?, "sections": [{ "id"?, "group", "title", "tag"?, "body" (markdown), "url"? (a live page shown instead of the body) }] }
// Sign-offs and notes save beside the deck as <deck>.signoff.json; "replyTo" names the claude-say session that Submit notifies.
// Learn reads a { "mode": "tutor", … } session file and writes answers beside it as <session>.answers.json.
import AppKit
import UniformTypeIdentifiers

/// The launcher writes this after a successful build, so a change means a newer Show is ready.
let buildStamp = ((Bundle.main.bundlePath as NSString).deletingLastPathComponent as NSString).appendingPathComponent("source.sha")

/// Where decks live; `SHOW_DIR` points a scratch build at fixtures instead.
let decksDirectory = ((ProcessInfo.processInfo.environment["SHOW_DIR"] ?? "~/.dotfiles/show") as NSString).expandingTildeInPath

/// Remembered selections, drafts and open documents; a snapshot run keeps its own so it never touches the real app's.
var prefs = UserDefaults.standard

/// The workspaces on the rail, top to bottom; the nth answers to ⌘n. Nothing crosses between them except the rail's waiting badges.
enum Workspace: String, CaseIterable {
    case forest, review, learn, runs

    var name: String { rawValue.capitalized }

    var symbol: String {
        switch self {
        case .forest: return "tree"
        case .review: return "rectangle.stack"
        case .learn: return "graduationcap"
        case .runs: return "dot.radiowaves.left.and.right"
        }
    }

    var key: String { "\((Workspace.allCases.firstIndex(of: self) ?? 0) + 1)" }

    /// The quiet tint on the selected rail tile and the window subtitle; Runs turns Signal orange only while a run is going.
    func tint(running: Bool = false) -> NSColor {
        switch self {
        case .forest: return forestTint
        case .review: return .secondaryLabelColor
        case .learn: return inkColor
        case .runs: return running ? .systemOrange : .secondaryLabelColor
        }
    }

    /// The workspace a file opens in: its `"workspace"` key when that names one, otherwise its `mode` (`kind` in older tutor files).
    static func route(_ path: String) -> (workspace: Workspace, reason: String) {
        struct Head: Decodable {
            let workspace: String?
            let mode: String?
            let kind: String?
        }
        let head = try? JSONDecoder().decode(Head.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        if let named = head?.workspace, let workspace = Workspace(rawValue: named.lowercased()) {
            return (workspace, "\"workspace\": \"\(named)\"")
        }
        let mode = head?.mode ?? head?.kind
        switch mode {
        case "forest": return (.forest, "mode \"forest\"")
        case "tutor": return (.learn, head?.mode == nil ? "kind \"tutor\"" : "mode \"tutor\"")
        case "live": return (.runs, "mode \"live\"")
        case let other?: return (.review, "mode \"\(other)\"")
        case nil: return (.review, "no mode")
        }
    }
}

/// One Show process and one window: `show <file>` hands the file to the running app, which switches to its workspace and opens it there.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, NSWindowDelegate {
    var window: NSWindow!
    var shell: ShellController!
    var workspaces: [Workspace: WorkspaceController] = [:]
    let launchPaths: [String]
    let snapshotPath: String?
    var watcher: Timer?
    var signature = ""
    let launchedBuild = modificationDate(buildStamp)

    init(launchPaths: [String], snapshotPath: String? = nil) {
        self.launchPaths = launchPaths
        self.snapshotPath = snapshotPath
    }

    var active: Workspace { shell.active }
    var tutor: TutorController? { workspaces[.learn]?.tutor }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let start = prefs.string(forKey: "workspace.active").flatMap(Workspace.init(rawValue:)) ?? .review
        for workspace in Workspace.allCases {
            let controller = WorkspaceController(workspace: workspace)
            controller.onTitleChange = { [weak self] in
                guard let self, self.shell != nil, self.active == workspace else { return }
                self.updateTitle()
            }
            controller.onLibraryChange = { [weak self] in
                guard let self, self.shell != nil else { return }
                self.refreshLibrary(force: true)
            }
            workspaces[workspace] = controller
        }
        shell = ShellController(workspaces: workspaces, active: start)
        shell.onPick = { [weak self] in self?.switchTo($0) }
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 780),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.delegate = self
        window.contentViewController = shell
        window.setContentSize(NSSize(width: 1180, height: 780))
        window.contentMinSize = NSSize(width: 45 + 200 + TutorController.margin + TutorController.column + 48, height: 480)
        if snapshotPath == nil {
            window.center()
            window.setFrameAutosaveName("show.window")
        }
        _ = shell.view
        workspaces.values.forEach { $0.settleColumns() }
        refreshLibrary(force: true)
        restore()
        updateTitle()
        launchPaths.forEach(openPath)
        if let snapshotPath {
            snapshot(to: snapshotPath)
            NSApp.terminate(nil)
            return
        }
        buildMenu()
        window.makeKeyAndOrderFront(nil)
        workspaces[active]?.restoreFocus(in: window)
        NSApp.activate(ignoringOtherApps: true)
        refreshLibrary(force: true)
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.charactersIgnoringModifiers == "/",
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                  !self.isTyping else { return event }
            self.showFinder(nil)
            return nil
        }
        watcher = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.stayCurrent() }
    }

    /// Reopens each workspace's last document, so a relaunch into a new build comes back where it was.
    private func restore() {
        for (workspace, controller) in workspaces {
            if let path = prefs.string(forKey: "workspace.\(workspace.rawValue).open"), FileManager.default.fileExists(atPath: path),
               Workspace.route(path).workspace == workspace {
                controller.open(path)
            } else {
                _ = controller.view
            }
        }
    }

    /// Reloads documents edited on disk, refreshes the rail's waiting badges, and relaunches into a newer build once the launcher finishes one.
    private func stayCurrent() {
        workspaces.values.forEach { $0.reloadChanged() }
        shell.runsRunning = workspaces[.runs]?.isRunning ?? false
        refreshLibrary()
        if let built = modificationDate(buildStamp), built != launchedBuild {
            relaunch()
        }
    }

    /// Rescans the library when anything in it changed: every workspace regroups its shelf, and the rail's badges count what waits on you.
    func refreshLibrary(force: Bool = false) {
        let fresh = librarySignature()
        guard force || fresh != signature else { return }
        signature = fresh
        let entries = scanLibrary()
        workspaces.values.forEach { $0.setEntries(entries) }
        var counts: [Workspace: Int] = [:]
        for entry in entries where entry.state == .waiting {
            counts[entry.workspace, default: 0] += 1
        }
        shell.setBadges(counts)
    }

    /// Whether keystrokes are going into a text field, where `/` is just a slash.
    private var isTyping: Bool {
        guard let responder = window.firstResponder as? NSTextView else { return false }
        return responder.isEditable
    }

    private func relaunch() {
        watcher?.invalidate()
        saveAll()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 0.7; open -a \"$0\"", Bundle.main.bundlePath]
        try? process.run()
        NSApp.terminate(nil)
    }

    private func saveAll() {
        workspaces.values.forEach { $0.saveState() }
        prefs.set(active.rawValue, forKey: "workspace.active")
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        urls.map(\.path).forEach(openPath)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        if snapshotPath == nil {
            saveAll()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Switches to the file's workspace and opens it there.
    func openPath(_ rawPath: String) {
        let path = canonicalPath(rawPath)
        let workspace = Workspace.route(path).workspace
        switchTo(workspace)
        workspaces[workspace]?.open(path)
        if snapshotPath == nil {
            window.makeKeyAndOrderFront(nil)
        }
    }

    /// Brings a workspace forward in the same window: its view swaps in, nothing else moves.
    func switchTo(_ workspace: Workspace) {
        guard workspace != active else { return }
        shell.hideFinder()
        workspaces[active]?.rememberFocus(in: window)
        shell.show(workspace)
        prefs.set(workspace.rawValue, forKey: "workspace.active")
        updateTitle()
        workspaces[workspace]?.restoreFocus(in: window)
    }

    func updateTitle() {
        guard let controller = workspaces[active] else { return }
        let detail = controller.current == nil ? "" : controller.subtitle
        shell.runsRunning = workspaces[.runs]?.isRunning ?? false
        shell.setTitle(controller.documentTitle, subtitle: [active.name, detail].filter { !$0.isEmpty }.joined(separator: " · "), running: controller.isRunning)
        window.title = controller.documentTitle
    }

    @objc func showWorkspace(_ sender: NSMenuItem) {
        switchTo(Workspace.allCases[sender.tag])
    }

    @objc func pickConfidence(_ sender: NSMenuItem) {
        tutor?.choose(confidence: sender.tag)
    }

    @objc func showFinder(_ sender: Any?) {
        guard let controller = workspaces[active] else { return }
        if shell.finder != nil {
            shell.hideFinder()
            controller.restoreFocus(in: window)
            return
        }
        controller.rememberFocus(in: window)
        shell.showFinder(entries: controller.entries) { [weak self] entry in
            self?.openPath(entry.path)
        }
    }

    /// ⌘⇧O: the selected branch's page in canopy, the native forest viewer, for its diff.
    @objc func openInCanopy(_ sender: Any?) {
        guard let controller = workspaces[active] else { return }
        guard active == .forest else {
            controller.say("⌘⇧O opens a branch in canopy from the Forest workspace")
            return
        }
        guard let deck = controller.currentDeck, let section = deck.selectedSection else {
            controller.say("Open a forest and pick a branch first")
            return
        }
        guard let command = canopyCommand(deck.deck, section) else {
            controller.say(section.rank == nil ? "“\(section.title)” isn't a branch, so canopy has no page for it" : "This forest deck names no repo, so canopy can't find the branch")
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command[0])
        process.arguments = Array(command.dropFirst())
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        process.terminationHandler = { [weak controller] finished in
            let detail = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").last.map(String.init) ?? ""
            guard finished.terminationStatus != 0 else { return }
            DispatchQueue.main.async {
                controller?.say("canopy failed (exit \(finished.terminationStatus))" + (detail.isEmpty ? "" : ": \(detail)"))
            }
        }
        do {
            try process.run()
            controller.say("Opening \(section.key) in canopy")
        } catch {
            controller.say("Couldn't run canopy: \(error.localizedDescription)")
        }
    }

    @objc func goBack(_ sender: Any?) {
        workspaces[active]?.goBack()
    }

    @objc func archiveSelected(_ sender: Any?) {
        workspaces[active]?.archiveSelected()
    }

    @objc func toggleShelf(_ sender: Any?) {
        guard let item = workspaces[active]?.split.splitViewItems.first else { return }
        item.animator().isCollapsed.toggle()
    }

    @objc func sendTutor(_ sender: Any?) {
        tutor?.sendFocused()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(sendTutor) {
            return active == .learn
        }
        if menuItem.action == #selector(pickConfidence) {
            return active == .learn && tutor?.currentRungID != nil
        }
        if menuItem.action == #selector(archiveSelected) {
            return workspaces[active].map { $0.shelf.selectedRow >= 0 } ?? false
        }
        if menuItem.action == #selector(goBack) {
            return workspaces[active]?.back.isEmpty == false
        }
        return true
    }

    @objc func openOther(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.directoryURL = URL(fileURLWithPath: decksDirectory)
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        panel.urls.map(\.path).forEach(openPath)
    }

    @objc func reloadCurrent(_ sender: Any?) {
        workspaces[active]?.reload()
    }

    private func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Show", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let libraryItem = NSMenuItem()
        main.addItem(libraryItem)
        let libraryMenu = NSMenu(title: "Library")
        libraryMenu.addItem(withTitle: "Find…", action: #selector(showFinder), keyEquivalent: "o").target = self
        let openFile = libraryMenu.addItem(withTitle: "Open File…", action: #selector(openOther), keyEquivalent: "o")
        openFile.keyEquivalentModifierMask = [.command, .option]
        openFile.target = self
        libraryMenu.addItem(withTitle: "Back", action: #selector(goBack), keyEquivalent: "[").target = self
        libraryMenu.addItem(withTitle: "Open Branch in Canopy", action: #selector(openInCanopy), keyEquivalent: "O").target = self
        libraryMenu.addItem(.separator())
        libraryMenu.addItem(withTitle: "Archive Shelf Row (⌫ on the shelf)", action: #selector(archiveSelected), keyEquivalent: "").target = self
        libraryMenu.addItem(withTitle: "Reload", action: #selector(reloadCurrent), keyEquivalent: "r").target = self
        libraryMenu.addItem(.separator())
        let toggle = libraryMenu.addItem(withTitle: "Toggle Shelf", action: #selector(toggleShelf), keyEquivalent: "s")
        toggle.keyEquivalentModifierMask = [.command, .control]
        toggle.target = self
        libraryItem.submenu = libraryMenu
        let workspaceItem = NSMenuItem()
        main.addItem(workspaceItem)
        let workspaceMenu = NSMenu(title: "Workspace")
        for (i, workspace) in Workspace.allCases.enumerated() {
            let item = NSMenuItem(title: workspace.name, action: #selector(showWorkspace), keyEquivalent: workspace.key)
            item.tag = i
            item.target = self
            workspaceMenu.addItem(item)
        }
        workspaceItem.submenu = workspaceMenu
        let tutorItem = NSMenuItem()
        main.addItem(tutorItem)
        let tutorMenu = NSMenu(title: "Tutor")
        let sendItem = NSMenuItem(title: "Send", action: #selector(sendTutor), keyEquivalent: "\r")
        sendItem.keyEquivalentModifierMask = [.command]
        sendItem.target = self
        tutorMenu.addItem(sendItem)
        tutorMenu.addItem(.separator())
        for (i, level) in confidenceLevels.enumerated() {
            let item = NSMenuItem(title: level.1, action: #selector(pickConfidence), keyEquivalent: "\(i + 1)")
            item.keyEquivalentModifierMask = [.control]
            item.tag = i
            item.target = self
            tutorMenu.addItem(item)
        }
        tutorItem.submenu = tutorMenu
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = main
    }
}
