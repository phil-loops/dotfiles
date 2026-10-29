import CanopyCore
import Foundation
import Observation

/// Everything one window runs on: the server door, the live store, the router, the command
/// registry + runner + modal keys, and the shell's UI state — the focus model (which pane, which
/// row, the select anchor), the `:` line, the layers. Pages get it as a parameter (or
/// `@Environment(AppModel.self)` in views) — never a global.
@MainActor
@Observable
public final class AppModel: CommandContext {
    @ObservationIgnored public let config: AppConfig
    @ObservationIgnored public let transport: Transport
    @ObservationIgnored public let telemetry: Telemetry
    @ObservationIgnored public let stream: EventStream
    @ObservationIgnored public let pulse: Pulse
    public let store: Store
    public let router: Router
    public let registry: CommandRegistry
    public let runner: Runner
    public let keys: KeyEngine
    public let nav: CodeNav
    /// The app-wide jumplist (NAV.md §4.4): `C-o` / `C-i` over pages and code places.
    public let jumps = Jumplist()

    public private(set) var bootstrap = Bootstrap()

    // ── the focus model: per pane (keyed "<surface>/<pane>"), a cursor row and a select anchor ──
    public private(set) var focusedPane: [String: String] = [:]
    public private(set) var cursors: [String: String] = [:]
    public private(set) var cursorIdxs: [String: Int] = [:]
    public private(set) var anchors: [String: Int] = [:]

    /// The label layer while it's up: what's labelled, and what's been typed of a label.
    public internal(set) var labeling: LabelSession?
    /// >0 while one jump is under way: the jump recorded its origin once, nothing inside re-records.
    @ObservationIgnored var jumpDepth = 0
    /// Branch visits, fuzzy × frecency for `space b` (seeded from the usage log at start).
    @ObservationIgnored public var frecency = Frecency()

    // ── the `:` line and insert mode ──
    public var cmdline = ""
    public var cmdIndex = 0
    /// The text field insert mode is typing into (a page's own id for it); nil when none.
    public private(set) var insertField: String?

    @ObservationIgnored public private(set) var surfaces: [String: SurfaceProvider] = [:]
    @ObservationIgnored public private(set) var installed: [String] = []
    @ObservationIgnored private var states: [ObjectIdentifier: AnyObject] = [:]
    /// What `esc` in normal mode (overlay.close) backs out of (app.ts: an armed push, a launch).
    /// The label layer's geometry: what views wearing `.labelTarget` / `.labelPane` reported.
    @ObservationIgnored private var targetGeometry: [String: LabelTarget] = [:]
    @ObservationIgnored private var targetOrder: [String] = []
    @ObservationIgnored private var paneFrames: [String: CGRect] = [:]
    @ObservationIgnored public private(set) var closers: [(isOpen: () -> Bool, close: () -> Void)] = []

    /// `protocolClasses` lets a test answer the app's requests with a URLProtocol stub.
    public init(config: AppConfig, port: Int, telemetry enabled: Bool = true, protocolClasses: [AnyClass]? = nil) {
        self.config = config
        transport = Transport(base: URL(string: "http://127.0.0.1:\(port)")!, protocolClasses: protocolClasses)
        telemetry = Telemetry(transport: transport, enabled: enabled)
        store = Store()
        router = Router(config.route)
        registry = CommandRegistry()
        runner = Runner(registry: registry, store: store, transport: transport, telemetry: telemetry)
        keys = KeyEngine(registry: registry, runner: runner)
        nav = CodeNav()
        stream = EventStream(transport: transport, store: store)
        pulse = Pulse(transport: transport)
        runner.context = self

        let tel = telemetry
        transport.count = { name, ms in Task { @MainActor in tel.count(name, ms) } }
        stream.count = { [weak self] name, ms in self?.telemetry.count(name, ms) }
        stream.onAsset = { [weak self] _ in Task { await self?.loadBootstrap() } }
        router.willNavigate = { [weak self] _, _ in self?.recordJump() }
        router.blocked = { [weak self] in self?.keys.cancelling == true ? "esc only cancels" : nil }
        router.onBlocked = { [weak self] to, why in
            Log.line("blocked a page change to \(to.path): \(why)")
            self?.runner.say(KeyEngine.nothingToCancel)
        }
        nav.record = { [weak self] in self?.recordJump() }
        router.onNavigate = { [weak self] from, to in
            self?.keys.reset()
            if let b = to.branchID { self?.frecency.visit(b) }
            self?.telemetry.emit(["type": "nav", "from": .string(from.surfaceID), "to": .string(to.surfaceID), "path": .string(to.path), "paintMs": nil])
            Log.line("nav \(from.path) → \(to.path)")
        }
        keys.onChange = { [weak self] from, to in self?.modeChanged(from, to) }
        nav.onPickerChange = { [weak self] open in
            guard let self else { return }
            if open { self.keys.openLayer(.picker) } else if self.keys.layer == .picker { self.keys.closeLayer() }
        }

        keys.layerKeys[.labels] = { [weak self] k in self?.labelKey(k) ?? false }

        ShellCommands.install(self)
        NavCommands.install(self)
        for area in Areas.all {
            area.install(self)
            installed.append(area.name)
        }
        registry.applyUserKeys([:])
    }

    /// Connect: read the bootstrap (repos + keys), then hydrate and hold the event stream.
    public func start() {
        stream.connect()
        Task { await loadBootstrap() }
        seedFrecency()
        runner.announce(surfaces: Surface.all)
    }

    public func loadBootstrap() async {
        do {
            let b = try await Bootstrap.fetch(transport)
            bootstrap = b
            Log.line("bootstrap: repos \(b.repos) · \(b.keys.count) key overrides · asset \(b.asset.prefix(8))")
        } catch {
            let (keys, errors) = KeysToml.load()
            bootstrap = Bootstrap(repos: store.repo.keys.sorted(), keys: keys, keyErrors: errors + ["bootstrap: \(error) — read keys.toml directly"])
            Log.line("bootstrap failed (\(error)); keys.toml read directly")
        }
        transport.repos = bootstrap.repos
        registry.applyUserKeys(bootstrap.keys, errors: bootstrap.keyErrors)
        if !registry.keyProblems.isEmpty { Log.line("key problems: \(registry.keyProblems.joined(separator: "; "))") }
    }

    // ── registration (areas call these from install) ──

    public func addSurface(_ p: SurfaceProvider) {
        precondition(surfaces[p.surfaceID] == nil, "surface \(p.surfaceID) registered twice")
        surfaces[p.surfaceID] = p
    }

    public func addCloser(isOpen: @escaping () -> Bool, close: @escaping () -> Void) { closers.append((isOpen, close)) }

    /// An area's own state object, made once on first ask and kept for the window's life.
    public func state<T: AnyObject>(_ make: () -> T) -> T {
        if let s = states[ObjectIdentifier(T.self)] as? T { return s }
        let s = make()
        states[ObjectIdentifier(T.self)] = s
        return s
    }

    // ── modes and layers ──

    public var menuOpen: Bool {
        get { keys.layer == .menu }
        set { newValue ? keys.openLayer(.menu) : (keys.layer == .menu ? keys.closeLayer() : ()) }
    }

    public var sheetOpen: Bool {
        get { keys.layer == .sheet }
        set { newValue ? keys.openLayer(.sheet) : (keys.layer == .sheet ? keys.closeLayer() : ()) }
    }

    /// Enter insert mode on a page's text field (its view focuses when `insertField` names it).
    public func beginInsert(_ field: String) {
        insertField = field
        keys.setMode(.insert)
    }

    private func modeChanged(_ from: KeyMode, _ to: KeyMode) {
        if from == .insert { insertField = nil }
        if from == .select && keys.mode != .select { anchors[paneKey] = nil }
        if from == .picker { nav.close() }
        if from == .labels { labeling = nil }
        if to == .command { cmdline = ""; cmdIndex = 0 }
    }

    // ── model.ts: panes, rows, the selection, scopes, targets ──

    public var provider: SurfaceProvider? { surfaces[router.surface.id] }

    public var panes: [Pane] { provider?.panes(self) ?? [] }

    /// The focused pane: the one focus names while it's on the page, else the first.
    public var pane: Pane? {
        let ps = panes
        let id = focusedPane[router.surface.id]
        return ps.first { $0.id == id } ?? ps.first
    }

    private var paneKey: String { "\(router.surface.id)/\(pane?.id ?? "main")" }

    public var rows: [String] { pane?.rows ?? [] }

    /// The focused pane's cursor row.
    public var cursor: String? {
        get { cursors[paneKey] }
        set { cursors[paneKey] = newValue }
    }

    public var cursorIdx: Int {
        get { cursorIdxs[paneKey] ?? 0 }
        set { cursorIdxs[paneKey] = newValue }
    }

    /// The cursor's row while it's visible, else whatever now sits in its place — so removing a
    /// row leaves the cursor on the next one.
    public var selected: String? {
        let r = rows
        if let c = cursor, r.contains(c) { return c }
        guard !r.isEmpty else { return nil }
        return r[max(0, min(cursorIdx, r.count - 1))]
    }

    /// The rows a command acts on: in select mode the range from the anchor to the cursor, else
    /// just the selected row. Multi-row commands (archive these, push these) read this.
    public var selection: [String] {
        let r = rows
        guard let sel = selected, let at = r.firstIndex(of: sel) else { return [] }
        guard keys.mode == .select, let a = anchors[paneKey] else { return [sel] }
        let lo = max(0, min(a, at)), hi = min(r.count - 1, max(a, at))
        return Array(r[lo...hi])
    }

    /// Whether this pane is the focused one (views draw their focus ring from it).
    public func isFocused(_ paneID: String) -> Bool { pane?.id == paneID }

    public func setCursor(_ key: String?) {
        cursor = key
        cursorIdx = max(0, rows.firstIndex(of: key ?? "") ?? 0)
    }

    public func cursorTo(_ i: Int) {
        let r = rows
        guard !r.isEmpty else { return }
        let n = max(0, min(r.count - 1, i))
        cursor = r[n]
        cursorIdx = n
    }

    public func moveCursor(_ by: Int) {
        let r = rows
        guard !r.isEmpty else { return }
        cursorTo((r.firstIndex(of: selected ?? r[0]) ?? 0) + by)
    }

    /// Drop the select anchor at the cursor (`v`).
    public func anchorHere() {
        anchors[paneKey] = rows.firstIndex(of: selected ?? "") ?? cursorIdx
    }

    public func focus(pane id: String) {
        guard panes.contains(where: { $0.id == id }) else { return }
        focusedPane[router.surface.id] = id
    }

    /// `C-w h/j/k/l`: the nearest pane that way on the grid; false when there's none.
    @discardableResult
    public func focus(_ d: Direction) -> Bool {
        guard let here = pane else { return false }
        let others = panes.filter { $0.id != here.id }
        let ahead: [Pane]
        switch d {
        case .left: ahead = others.filter { $0.column < here.column }
        case .right: ahead = others.filter { $0.column > here.column }
        case .up: ahead = others.filter { $0.row < here.row }
        case .down: ahead = others.filter { $0.row > here.row }
        }
        let best = ahead.min { abs($0.column - here.column) + abs($0.row - here.row) < abs($1.column - here.column) + abs($1.row - here.row) }
        guard let best else { return false }
        focus(pane: best.id)
        return true
    }

    public func target(for scope: Scope) -> String? {
        if let t = provider?.target(for: scope, self) { return t }
        switch scope {
        case .row: return selected
        case .project: return RowKey.id(selected, "p")
        case .branch: return RowKey.id(selected, "b")
        case .review: return router.route.branchID
        case .machine: return "machine"
        default: return nil
        }
    }

    public func liveScopes() -> [Scope] {
        var out = provider?.scopes(self) ?? []
        let own = Scope(rawValue: router.surface.id)
        if !out.contains(own) { out.append(own) }
        out.append(.global)
        return out
    }

    public func closeMenu() { menuOpen = false }

    // ── the `:` line ──

    public var completions: [Command] { keys.completions(cmdline) }

    /// Run the highlighted completion, as a palette run.
    public func runCmdline() {
        let c = completions
        guard c.indices.contains(cmdIndex) else { return runner.say("no command \(cmdline)") }
        let id = c[cmdIndex].id
        keys.setMode(.normal)
        runner.dispatch(id, via: .palette)
    }

    // ── navigation helpers ──

    public func go(_ r: Route) { router.navigate(r) }

    // ── navigation seams: where things are (labels) and where we are (the jumplist) ──

    public func noteTarget(_ t: LabelTarget) {
        let k = "\(t.pane)\u{1}\(t.key)"
        if targetGeometry.updateValue(t, forKey: k) == nil { targetOrder.append(k) }
    }

    public func dropTarget(pane: String, key: String) {
        let k = "\(pane)\u{1}\(key)"
        if targetGeometry.removeValue(forKey: k) != nil { targetOrder.removeAll { $0 == k } }
    }

    public func notePaneFrame(_ pane: String, _ rect: CGRect?) { paneFrames[pane] = rect }

    /// What's on screen to label: every reported target that belongs to this page — a row target
    /// only while its pane is on the page and holds that row, and only inside its pane's visible
    /// frame — titled by the surface when it carries no title of its own.
    public func visibleTargets() -> [LabelTarget] {
        let ps = panes
        return targetOrder.compactMap { targetGeometry[$0] }.compactMap { t in
            var t = t
            if let p = ps.first(where: { $0.id == t.pane }) {
                guard p.rows.contains(t.key) else { return nil }
                if t.title.isEmpty { t.title = provider?.title(for: t.key, self) ?? t.key }
            } else if t.run == nil {
                return nil
            }
            if let f = paneFrames[t.pane], !f.intersects(t.rect) { return nil }
            return t
        }
    }

    /// A row's text when its surface says nothing better: the entity's name, else the key's id.
    public func guessTitle(_ row: String) -> String {
        if let id = RowKey.id(row, "b") { return store.view(Branch.self, id)?.name ?? id }
        if let id = RowKey.id(row, "p") { return store.view(Project.self, id)?.name ?? id }
        if let i = row.firstIndex(of: ":") { return String(row[row.index(after: i)...]) }
        return row
    }

    /// Where we are, exactly (a jumplist entry): route, pane, cursor, code place, plus what the
    /// surface keeps (`remember`: its tab and scroll).
    public func here() -> Place {
        var p = Place(route: router.route, pane: pane?.id, cursorKey: selected, loc: nav.here)
        provider?.remember(&p, self)
        return p
    }
}
