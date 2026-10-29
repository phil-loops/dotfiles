import Foundation
import Observation

/// Where a command applies (registry.ts Scope). Open: an area adds its own with
/// `extension Scope { static let mine: Scope = "mine" }` in its own folder, then lists it under its
/// surface with `CommandRegistry.addScopes`.
public struct Scope: OpenString {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let global: Scope = "global", forests: Scope = "forests", dashboard: Scope = "dashboard"
    public static let row: Scope = "row", project: Scope = "project", branch: Scope = "branch"
    public static let review: Scope = "review", line: Scope = "line", thread: Scope = "thread"
    public static let pending: Scope = "pending", gap: Scope = "gap", history: Scope = "history", commit: Scope = "commit"
    public static let todo: Scope = "todo", item: Scope = "item", forest: Scope = "forest"
    public static let machine: Scope = "machine", server: Scope = "server"
    public static let wiki: Scope = "wiki", article: Scope = "article"
    public static let tutor: Scope = "tutor", concept: Scope = "concept", lesson: Scope = "lesson", session: Scope = "session"
}

/// Which keymap is live (Helix-style modes, plus the transient layers that own the keyboard while
/// they're up). A command binds its keys in the modes it lists — `normal` unless it says otherwise.
/// Open: an area adds a layer of its own (`extension KeyMode { static let compose: KeyMode = "compose" }`).
public struct KeyMode: OpenString {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    /// navigate and act — the default
    public static let normal: KeyMode = "normal"
    /// text entry: keys go to the focused field except the ones bound here (esc always backs out)
    public static let insert: KeyMode = "insert"
    /// ranges: j/k extend from the anchor `v` dropped
    public static let select: KeyMode = "select"
    /// the `:` line: type a command, fuzzy-completed
    public static let command: KeyMode = "command"
    /// layers: the space menu, the `?` sheet, the code picker
    public static let menu: KeyMode = "menu"
    public static let sheet: KeyMode = "sheet"
    public static let picker: KeyMode = "picker"
    /// the label layer (`g w` / `f`): every visible target wears a label; typing one picks it
    public static let labels: KeyMode = "labels"

    /// Modes whose printable keys go to a text field.
    public static var textEntry: Set<KeyMode> = [.insert, .command, .menu, .picker]

    /// The statusline's badge.
    public var badge: String {
        switch self {
        case .normal: "NOR"
        case .insert: "INS"
        case .select: "SEL"
        case .command: "CMD"
        default: rawValue.prefix(3).uppercased()
        }
    }
}

/// Latency budget classes (budgets.ts); the dashboard reads the table from the registry event.
public enum Budget: String, Sendable, CaseIterable {
    case local, configWrite = "config-write", gitWrite = "git-write", slowIO = "slow-io"

    public var feedbackMs: Double { 16.7 }
    public var settledMs: Double? {
        switch self { case .local: nil; case .configWrite: 300; case .gitWrite: 3000; case .slowIO: 15000 }
    }
}

public let PAINT_MS = 100.0

/// The command that puts a write back, for `u`.
public struct Inverse {
    public var id: String
    public var target: String
    public var arg: Any?
    public init(id: String, target: String, arg: Any? = nil) { self.id = id; self.target = target; self.arg = arg }
}

/// A command refuses by throwing this; the message is the quiet line ("nothing to undo").
public struct Refusal: Error, CustomStringConvertible {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// An optimistic server write (registry.ts Write): shown at once, posted in the background, kept
/// until settled.
public struct Write {
    public var ops: [Op]
    public var path: String
    public var body: JSONValue
    /// true once the server's copy (not the overlay) reflects this write
    public var settled: () -> Bool
    /// one quiet line after it lands (undo hint)
    public var said: String?
    /// the line if it's refused
    public var failed: String
    /// the command that puts it back — or a function of the server's answer when only it knows
    public var inverse: ((JSONObject) -> Inverse?)?
    /// undo a local (non-store) part of the optimistic change when the server refuses
    public var rollback: (() -> Void)?
    /// the server's answer, whatever it was — for a caller chaining steps on it
    public var answered: ((Bool, JSONObject) -> Void)?
    /// the caller says what happened itself: no quiet line on success or refusal
    public var silent = false
    /// post at once, beside the FIFO queue (a long run mustn't hold up every write behind it)
    public var alone = false

    public init(ops: [Op] = [], path: String, body: JSONValue, settled: @escaping () -> Bool, said: String? = nil, failed: String,
                inverse: ((JSONObject) -> Inverse?)? = nil, rollback: (() -> Void)? = nil,
                answered: ((Bool, JSONObject) -> Void)? = nil, silent: Bool = false, alone: Bool = false) {
        self.ops = ops; self.path = path; self.body = body; self.settled = settled; self.said = said; self.failed = failed
        self.inverse = inverse; self.rollback = rollback; self.answered = answered; self.silent = silent; self.alone = alone
    }
}

/// Where a `route` command sends the key on to.
public struct RouteTo {
    public var id: String
    public var target: String?
    public var arg: Any?
    public init(_ id: String, target: String? = nil, arg: Any? = nil) { self.id = id; self.target = target; self.arg = arg }
}

/// Every action the app can take (registry.ts Command). Keys, buttons, the space menu and the
/// palette all dispatch by id through the Runner.
public struct Command {
    public var id: String
    public var title: String
    public var scope: Scope
    public var budget: Budget
    public var keys: [String]
    /// the modes its keys bind in
    public var modes: [KeyMode]
    /// only ever run with an argument another view supplies (a found branch, a row index): exempt
    /// from the rule that every command is bound or runnable from `:`
    public var needsArg: Bool
    /// one word for the hint line ("line", "reply"); the title's first clause when absent
    public var label: String?
    /// its opposite (next ↔ previous): the hint line shows the two as one
    public var pair: String?
    /// keys a component handles itself (a text box's ⌘↵): shown in the sheet, never bound
    public var hint: [String]
    /// v1 telemetry ids this replaces
    public var v1: [String]
    /// left out of the space menu (cursor motion, the menu itself)
    public var quiet: Bool
    /// runs as a jump (NAV.md §4.4): the jumplist remembers where you were before it runs.
    /// Page changes record on their own; ids in `NavKeys.jumps` get this set on register.
    public var recordsJump: Bool
    public var available: ((String?) -> Bool)?
    /// a key that means "the right thing here": names the command that actually runs
    public var route: ((String?) -> RouteTo?)?
    /// a local effect; throw `Refusal` to refuse with a quiet line
    public var local: ((_ target: String?, _ arg: Any?) throws -> Void)?
    /// a server write; throw `Refusal` to refuse before sending
    public var write: ((_ target: String, _ arg: Any?) throws -> Write?)?

    public init(id: String, title: String, scope: Scope, budget: Budget = .local, keys: [String] = [],
                modes: [KeyMode] = [.normal], needsArg: Bool = false, label: String? = nil,
                pair: String? = nil, hint: [String] = [], v1: [String] = [], quiet: Bool = false,
                recordsJump: Bool = false,
                available: ((String?) -> Bool)? = nil, route: ((String?) -> RouteTo?)? = nil,
                local: ((_ target: String?, _ arg: Any?) throws -> Void)? = nil,
                write: ((_ target: String, _ arg: Any?) throws -> Write?)? = nil) {
        self.id = id; self.title = title; self.scope = scope; self.budget = budget; self.keys = keys; self.label = label
        self.modes = modes; self.needsArg = needsArg
        self.pair = pair; self.hint = hint; self.v1 = v1; self.quiet = quiet; self.recordsJump = recordsJump; self.available = available
        self.route = route; self.local = local; self.write = write
    }
}

/// The registry: every command, by id, in registration order. Keys can be overridden by
/// keys.toml (`applyUserKeys`), which always starts again from each command's default keys.
@MainActor
@Observable
public final class CommandRegistry {
    public private(set) var byID: [String: Command] = [:]
    public private(set) var order: [String] = []
    @ObservationIgnored private var defaults: [String: [String]] = [:]
    /// Ids whose keys come from keys.toml, and what couldn't be applied (shown atop the key sheet).
    public private(set) var customized: Set<String> = []
    public private(set) var keyProblems: [String] = []
    /// Which scopes each surface shows (sheet.ts SURFACE_SCOPES). Areas add theirs.
    public private(set) var surfaceScopes: [String: [Scope]] = CommandRegistry.defaultSurfaceScopes
    /// Bumped whenever keys change, so the keymap rebuilds.
    public private(set) var keysVersion = 0

    public init() {}

    public func register(_ c: Command) {
        precondition(byID[c.id] == nil, "command \(c.id) registered twice")
        var c = c
        if NavKeys.jumps.contains(c.id) { c.recordsJump = true }
        byID[c.id] = c
        order.append(c.id)
        defaults[c.id] = c.keys
        keysVersion += 1
    }

    public func register(_ cs: [Command]) { cs.forEach(register) }

    public var commands: [Command] { order.compactMap { byID[$0] } }
    public func command(_ id: String) -> Command? { byID[id] }

    /// The key a hint names for a command — its first, after keys.toml.
    public func keyOf(_ id: String) -> String { glyph(byID[id]?.keys.first ?? "space") }

    public func addScopes(_ scopes: [Scope], to surface: String) {
        var cur = surfaceScopes[surface] ?? []
        for s in scopes where !cur.contains(s) { cur.append(s) }
        surfaceScopes[surface] = cur
    }

    /// Lay keys.toml over the defaults (userkeys.ts), then check the one-meaning rule.
    public func applyUserKeys(_ overrides: [String: [String]], errors: [String] = []) {
        for (id, keys) in defaults { byID[id]?.keys = keys }
        customized = Set(overrides.keys)
        var bound = commands.map { Bound(id: $0.id, scope: $0.scope.rawValue, keys: $0.keys, modes: $0.modes.map(\.rawValue)) }
        let problems = Bindings.applyKeys(&bound, overrides)
        for b in bound { byID[b.id]?.keys = b.keys }
        keyProblems = errors + problems + Bindings.clashes(bound, surfaceScopes: surfaceScopes.mapValues { $0.map(\.rawValue) })
        keysVersion += 1
    }

    public static let defaultSurfaceScopes: [String: [Scope]] = [
        "forests": [.branch, .project, .row, .forests],
        "review": [.history, .commit, .pending, .thread, .line, .gap, .review],
        "dashboard": [.dashboard],
        "todo": [.item, .todo],
        "forest": [.branch, .row, .forest, .project],
        "machine": [.server, .machine],
        "wiki": [.article, .wiki],
        "tutor": [.concept, .lesson, .session, .tutor],
    ]

    public static let scopeTitles: [String: String] = [
        "global": "Everywhere", "forests": "On Forests", "row": "On a forest or branch", "project": "On a forest",
        "branch": "On a branch", "dashboard": "On the dashboard", "review": "Reviewing a branch", "line": "On a diff line",
        "thread": "On a conversation", "pending": "On a pending comment", "gap": "On hidden lines", "history": "In the history",
        "commit": "In one commit", "todo": "On the tracker", "item": "On an item", "forest": "On a forest's page",
        "machine": "On the machine", "server": "On a server", "wiki": "On the wiki", "article": "On a page in the list",
        "tutor": "On the tutor", "concept": "On a concept", "lesson": "On a session you keep", "session": "In a session",
    ]
}

/// A key as it reads on screen (registry.ts glyph): ⇧s for S, ⇥ tab, ↵ ret, ⌃k for C-k.
public func glyph(_ k: String) -> String {
    let named = ["tab": "⇥", "ret": "↵", "down": "↓", "up": "↑", "left": "←", "right": "→"]
    return k.split(separator: " ").map { tok -> String in
        let t = String(tok)
        if let n = named[t] { return n }
        var mod = ""
        var rest = Substring(t)
        if t.count == 3, t.hasPrefix("C-") { mod = "⌃"; rest = rest.dropFirst(2) }
        else if t.count == 3, t.hasPrefix("A-") { mod = "⌥"; rest = rest.dropFirst(2) }
        guard rest.count == 1, let ch = rest.first else { return t }
        let s = String(ch)
        return mod + (s != s.lowercased() ? "⇧\(s.lowercased())" : s)
    }.joined(separator: " ")
}

/// A title's first clause, lowercase (WhichKey.tsx short): "Show outdated conversations — …" → "show outdated conversations".
public func shortTitle(_ title: String) -> String {
    var t = title
    for sep in [" — ", " (", ", or "] { if let r = t.range(of: sep) { t = String(t[..<r.lowerBound]) } }
    t = t.trimmingCharacters(in: .whitespaces)
    return t.prefix(1).lowercased() + t.dropFirst()
}
