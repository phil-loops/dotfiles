// Show — one native window with workspaces on a rail: Canopy (⌘1), Learn (⌘2), Machine (⌘3), Inbox (⌘4); Forest, Review, Runs and API have no tile and open when a document routes to them.
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
    case canopy, learn, machine, inbox, forest, review, runs, api

    var name: String { self == .api ? "API" : rawValue.capitalized }

    var symbol: String {
        switch self {
        case .forest: return "tree"
        case .review: return "rectangle.stack"
        case .learn: return "graduationcap"
        case .runs: return "dot.radiowaves.left.and.right"
        case .api: return "bolt"
        case .canopy: return "leaf"
        case .machine: return "server.rack"
        case .inbox: return "tray"
        }
    }

    /// The workspaces with a rail tile and a ⌘ number; the rest open only when a document routes to them.
    static let onRail: [Workspace] = [.canopy, .learn, .machine, .inbox]

    var key: String { Workspace.onRail.firstIndex(of: self).map { "\($0 + 1)" } ?? "" }

    /// Canopy runs in it: the Canopy workspace, and Machine, canopy's machine page on its own key.
    var hostsCanopy: Bool { self == .canopy || self == .machine }

    /// The quiet tint on the selected rail tile and the window subtitle; Runs turns Signal orange only while a run is going.
    func tint(running: Bool = false) -> NSColor {
        switch self {
        case .forest: return forestTint
        case .review: return .secondaryLabelColor
        case .learn: return inkColor
        case .runs: return running ? .systemOrange : .secondaryLabelColor
        case .api: return .secondaryLabelColor
        case .canopy: return forestTint
        case .machine: return .secondaryLabelColor
        case .inbox: return .secondaryLabelColor
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
    /// Requests that came in before the window existed (a launch by opening a file can do that);
    /// handled once launching finishes. nil from then on.
    private var openedEarly: [ShowRequest]? = []

    init(launchPaths: [String], snapshotPath: String? = nil) {
        self.launchPaths = launchPaths
        self.snapshotPath = snapshotPath
    }

    var active: Workspace { shell.active }
    var tutor: TutorController? { workspaces[.learn]?.tutor }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let start = prefs.string(forKey: "workspace.active").flatMap(Workspace.init(rawValue:)) ?? .canopy
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
        for hosted in [Workspace.canopy, .machine] {
            workspaces[hosted]?.canopy?.isActive = { [weak self] in self?.active == hosted && self?.shell.finder == nil && self?.shell.overlay == nil }
        }
        shell = ShellController(workspaces: workspaces, active: start)
        shell.onPick = { [weak self] in self?.switchTo($0) }
        shell.onUpdate = { [weak self] in self?.relaunch() }
        window = ShowWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 780),
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
        if snapshotPath == nil && selfTest == nil {
            window.center()
            window.setFrameAutosaveName("show.window")
        }
        _ = shell.view
        installKeys()
        workspaces.values.forEach { $0.settleColumns() }
        LearnDue.onChange = { [weak self] in
            guard let learn = self?.workspaces[.learn] else { return }
            learn.setEntries(learn.entries)
        }
        LearnDue.refresh(sync: snapshotPath != nil)
        Topics.onChange = { [weak self] in
            guard let self, self.shell != nil else { return }
            self.refreshLibrary(force: true)
        }
        ArrivalNotices.shared.onOpen = { [weak self] target in
            self?.handle(.phil(target))
        }
        workspaces[.canopy]?.canopy?.onNavigate = { route in
            showEvents.append(ShowEvent(kind: .opened, target: .canopy(route), workspace: .canopy, title: canopyTitle(route)))
        }
        refreshLibrary(force: true)
        restore()
        updateTitle()
        let early = openedEarly ?? []
        openedEarly = nil
        let loud = early.filter(comesForward)
        launchPaths.forEach(openPath)
        loud.forEach { open($0.target) }
        if launchPaths.isEmpty, loud.isEmpty, snapshotPath == nil, selfTest == nil, workspaces.values.allSatisfy({ $0.current == nil }) {
            openNewest()
        }
        if let snapshotPath {
            snapshot(to: snapshotPath)
            NSApp.terminate(nil)
            return
        }
        installMenus()
        if let selfTest {
            exit(runSelfTest(selfTest))
        }
        // Started by a quiet `show <file>` or a relaunch into a new build while Show sat behind: the window waits at the back.
        let background = CommandLine.arguments.contains("--background") || (!early.isEmpty && loud.isEmpty)
        if background {
            window.orderBack(nil)
        } else {
            window.makeKeyAndOrderFront(nil)
        }
        workspaces[active]?.console?.start()
        workspaces[active]?.canopy?.start()
        workspaces[active]?.restoreFocus(in: window)
        if !background {
            NSApp.activate(ignoringOtherApps: true)
        }
        early.filter { !comesForward($0) }.forEach(arrive)
        refreshLibrary(force: true)
        watcher = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.stayCurrent() }
    }

    /// Reopens each workspace's last document from the event log, and canopy at the spot it saved, so a relaunch into a new build comes back where it was.
    private func restore() {
        for (workspace, controller) in workspaces {
            if case .document(let path)? = showEvents.state.current[workspace], FileManager.default.fileExists(atPath: path),
               Workspace.route(path).workspace == workspace {
                controller.open(path)
            } else if let canopy = controller.canopy, let place = prefs.string(forKey: controller.canopyPlaceKey) ?? lastCanopyRoute(workspace) {
                canopy.resume(at: place)
            } else {
                _ = controller.view
            }
        }
    }

    /// Reloads documents edited on disk, refreshes the rail's waiting badges, and offers Update once the launcher finishes a newer build.
    private func stayCurrent() {
        workspaces.values.forEach { $0.reloadChanged() }
        shell.runsRunning = workspaces[.runs]?.isRunning ?? false
        refreshLibrary()
        if let built = modificationDate(buildStamp), built != launchedBuild {
            shell.updateButton.isHidden = false
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
        counts[.canopy] = showEvents.state.waiting.filter { $0.workspace == .canopy }.count
        shell.setBadges(counts)
    }

    func relaunch() {
        watcher?.invalidate()
        saveAll()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        let waitForExit = "i=0; while kill -0 \"$1\" 2>/dev/null && [ $i -lt 200 ]; do sleep 0.05; i=$((i+1)); done; "
        let open = NSApp.isActive ? "open -a \"$0\"" : "open -g -a \"$0\" --args --background"
        process.arguments = ["-c", waitForExit + open, Bundle.main.bundlePath, String(ProcessInfo.processInfo.processIdentifier)]
        try? process.run()
        NSApp.terminate(nil)
    }

    private func lastCanopyRoute(_ workspace: Workspace) -> String? {
        guard case .canopy(let route)? = showEvents.state.current[workspace], !route.isEmpty else { return nil }
        return route
    }

    func saveAll() {
        workspaces.values.forEach { $0.saveState() }
        prefs.set(active.rawValue, forKey: "workspace.active")
    }

    /// Every door into Show lands here: a launcher's inbox file carries its own request; a canopy:// link or any other file
    /// (Finder, `open`) is Phil's own and comes forward.
    func application(_ application: NSApplication, open urls: [URL]) {
        let requests = urls.compactMap { url -> ShowRequest? in
            if url.scheme == "canopy" {
                return .phil(Target(canopyLink: url))
            }
            return takeInboxRequest(url.path) ?? .phil(.document(canonicalPath(url.path)))
        }
        if openedEarly != nil {
            openedEarly?.append(contentsOf: requests)
            return
        }
        requests.forEach(handle)
    }

    /// Puts `target` in front: its workspace, opened there.
    func open(_ target: Target) {
        switch target {
        case .document(let path):
            openPath(path)
        case .canopy(let route):
            switchTo(.canopy)
            workspaces[.canopy]?.canopy?.start(route: route.isEmpty ? nil : route)
        case .api:
            switchTo(.api)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if snapshotPath == nil {
            saveAll()
        }
    }

    /// A bare `show` while Show runs: the window comes forward as it was.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
        return false
    }

    /// First launch with nothing saved: the most recently touched document, in its workspace.
    private func openNewest() {
        if let newest = workspaces.values.flatMap(\.entries).max(by: { $0.touched < $1.touched }) {
            openPath(newest.path)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func windowDidBecomeKey(_ notification: Notification) {
        LearnDue.refresh()
    }

    /// Switches to the file's workspace and opens it there.
    func openPath(_ rawPath: String) {
        let path = canonicalPath(rawPath)
        let workspace = Workspace.route(path).workspace
        switchTo(workspace)
        workspaces[workspace]?.open(path)
        if snapshotPath == nil && selfTest == nil {
            window.makeKeyAndOrderFront(nil)
        }
    }

    /// Brings a workspace forward in the same window: its view swaps in, nothing else moves.
    func switchTo(_ workspace: Workspace) {
        if snapshotPath == nil && selfTest == nil {
            workspaces[workspace]?.console?.start()
            workspaces[workspace]?.canopy?.start()
        }
        guard workspace != active else { return }
        shell.hideFinder()
        workspaces[active]?.rememberFocus(in: window)
        shell.show(workspace)
        prefs.set(workspace.rawValue, forKey: "workspace.active")
        updateTitle()
        workspaces[workspace]?.restoreFocus(in: window)
        scopeMenus()
        updateFocusOutline()
    }

    func updateTitle() {
        guard let controller = workspaces[active] else { return }
        let detail = controller.current == nil ? "" : controller.subtitle
        shell.runsRunning = workspaces[.runs]?.isRunning ?? false
        shell.setTitle(controller.documentTitle, subtitle: [active.name, detail].filter { !$0.isEmpty }.joined(separator: " · "), running: controller.isRunning)
        window.title = controller.documentTitle
    }

    @objc func showFinder(_ sender: Any?) {
        guard let controller = workspaces[active] else { return }
        shell.hideOverlay()
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

    /// ⌘⇧O: the selected branch's page in the Canopy workspace, for its diff.
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
        guard let route = canopyRoute(deck.deck, section) else {
            controller.say(section.rank == nil ? "“\(section.title)” isn't a branch, so canopy has no page for it" : "This forest deck names no repo, so canopy can't find the branch")
            return
        }
        switchTo(.canopy)
        workspaces[.canopy]?.canopy?.start(route: route)
    }

    @objc func goBack(_ sender: Any?) {
        workspaces[active]?.goBack()
    }

    /// ⌘4: the Inbox workspace, opened on the messages Claude sessions post with `show-note`.
    @objc func openInbox() {
        guard FileManager.default.fileExists(atPath: inboxPath) else { return switchTo(.inbox) }
        openPath(inboxPath)
    }

    /// ⌘Y: everything that arrived or was opened, in every workspace, newest first; type a workspace or topic to narrow it.
    @objc func showHistory(_ sender: Any?) {
        guard let controller = workspaces[active] else { return }
        shell.hideOverlay()
        if shell.finder != nil {
            shell.hideFinder()
            controller.restoreFocus(in: window)
            return
        }
        controller.rememberFocus(in: window)
        shell.showFinder(entries: historyEntries(showEvents), placeholder: "History", searchesDetail: true) { [weak self] entry in
            self?.openHistory(Target(key: entry.path))
        }
    }

    private func openHistory(_ target: Target) {
        if case .document(let path) = target, !FileManager.default.fileExists(atPath: path) {
            workspaces[active]?.say("\((path as NSString).lastPathComponent) is gone (archived or removed)")
            return
        }
        open(target)
    }

    @objc func archiveSelected(_ sender: Any?) {
        workspaces[active]?.archiveSelected()
    }

    @objc func toggleShelf(_ sender: Any?) {
        guard let item = workspaces[active]?.split.splitViewItems.first else { return }
        item.animator().isCollapsed.toggle()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(runBinding), let id = menuItem.representedObject as? String, let binding = KeyTable.binding(id) else { return true }
        return isEnabled(binding)
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
}
