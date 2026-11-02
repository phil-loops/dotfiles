import Foundation

/// Helix-style key handling (keys.ts): single keys, `space` for the command menu, and chords written
/// as space-separated sequences ("g d"). Pure.
public struct KeyBinding: Equatable, Sendable {
    public var id: String
    public var keys: [String]
    public var scope: String
    public var modes: [String]
    public init(id: String, keys: [String], scope: String, modes: [String] = ["normal"]) {
        self.id = id; self.keys = keys; self.scope = scope; self.modes = modes
    }
}

public enum Fed: Equatable, Sendable {
    case run(String)
    case pending(String)
    case none
}

public struct Keymap {
    public var bindings: [KeyBinding]
    private var buf: [String] = []

    public init(_ bindings: [KeyBinding]) { self.bindings = bindings }

    public var pending: String { buf.joined(separator: " ") }

    /// Feed one key; `scopes` is the live scopes, narrowest first (it breaks ties); only bindings
    /// of `mode` are live.
    public mutating func feed(_ key: String, scopes: [String], mode: String = "normal") -> Fed {
        buf.append(key)
        let seq = buf.joined(separator: " ")
        let live = bindings.filter { scopes.contains($0.scope) && $0.modes.contains(mode) }
        let hits = live.filter { $0.keys.contains(seq) }
        if !hits.isEmpty {
            buf = []
            let best = hits.min { (scopes.firstIndex(of: $0.scope) ?? .max) < (scopes.firstIndex(of: $1.scope) ?? .max) }!
            return .run(best.id)
        }
        if live.contains(where: { $0.keys.contains { $0.hasPrefix(seq + " ") } }) { return .pending(seq) }
        buf = []
        return .none
    }

    public mutating func reset() { buf = [] }
}

/// A key press as a key name (keys.ts keyName): "x", "G", "?", "space", "esc", "ret", "down", "C-k".
/// ⌘ combinations are never page keys — they stay with the menu bar.
public enum KeyName {
    public static func name(key: String, ctrl: Bool = false, meta: Bool = false, alt: Bool = false) -> String? {
        let named = [" ": "space", "Escape": "esc", "Enter": "ret", "ArrowDown": "down", "ArrowUp": "up",
                     "ArrowLeft": "left", "ArrowRight": "right", "Tab": "tab"]
        guard let k = named[key] ?? (key.count == 1 ? key : nil) else { return nil }
        if meta { return nil }
        return ctrl ? "C-\(k)" : alt ? "A-\(k)" : k
    }

    /// macOS virtual key codes for the named keys (Carbon kVK_*).
    public static let codes: [UInt16: String] = [
        49: " ", 53: "Escape", 36: "Enter", 76: "Enter", 48: "Tab",
        125: "ArrowDown", 126: "ArrowUp", 123: "ArrowLeft", 124: "ArrowRight",
    ]

    /// From an AppKit key event's parts. `characters` is what the key typed (shift applied);
    /// `charactersIgnoringModifiers` is used under ⌃/⌥ so ⌃k reads "C-k" and ⌥a "A-a" (the browser
    /// on a Mac would say "A-å").
    public static func name(keyCode: UInt16, characters: String?, charactersIgnoringModifiers: String?,
                            ctrl: Bool, meta: Bool, alt: Bool) -> String? {
        if let n = codes[keyCode] { return name(key: n, ctrl: ctrl, meta: meta, alt: alt) }
        let chars = (ctrl || alt) ? charactersIgnoringModifiers : characters
        guard let c = chars, c.count == 1, let scalar = c.unicodeScalars.first, scalar.value >= 0x20, scalar.value != 0x7F,
              !(0xF700...0xF8FF).contains(scalar.value) else { return nil }
        return name(key: c, ctrl: ctrl, meta: meta, alt: alt)
    }
}

/// What the `?` sheet shows (sheet.ts sheetNow): each key once, as the command it would run here,
/// split into what works on the thing under the cursor, what works anywhere, and the page's keys
/// that do nothing at the moment.
public struct SheetCmd: Equatable, Sendable {
    public var id: String
    public var title: String
    public var scope: String
    public var keys: [String]
    public var available: Bool
    /// the verb it is (what the sheet says first), nil for a key under the page's leader
    public var verb: String?
    /// `Command.sheetGroup`'s raw value, for the page's own and global commands
    public var group: String?
    /// its opposite's id (next ↔ previous): the sheet shows the two as one line
    public var pair: String?
    /// how much it's used (frecency): within a section the most used comes first
    public var uses: Double
    /// one word for it (`Command.label`), what a joined line (the numbered tabs) lists
    public var label: String?
    public init(id: String, title: String, scope: String, keys: [String], available: Bool, verb: String? = nil,
                group: String? = nil, pair: String? = nil, uses: Double = 0, label: String? = nil) {
        self.id = id; self.title = title; self.scope = scope; self.keys = keys; self.available = available; self.verb = verb
        self.group = group; self.pair = pair; self.uses = uses; self.label = label
    }
}

public struct SheetLine: Equatable, Sendable {
    public var key: String
    public var cmd: SheetCmd
}

public func sheetNow(surface: String, live: [String], cmds: [SheetCmd], surfaceScopes: [String: [String]])
    -> (now: [SheetLine], everywhere: [SheetLine], notNow: [SheetLine])
{
    let mine = Set((surfaceScopes[surface] ?? []) + ["global"])
    let here = cmds.filter { mine.contains($0.scope) && !$0.keys.isEmpty }
    func rank(_ c: SheetCmd) -> Int { live.firstIndex(of: c.scope) ?? Int.max }
    var winner: [String: SheetCmd] = [:]
    var winOrder: [String] = []
    for c in here.enumerated().sorted(by: { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }).map(\.element) {
        if rank(c) == Int.max { continue }
        for k in c.keys where winner[k] == nil { winner[k] = c; winOrder.append(k) }
    }
    var now: [SheetLine] = []
    var everywhere: [SheetLine] = []
    var shown = Set<String>()
    let byScope = winOrder.enumerated().sorted { (rank(winner[$0.element]!), $0.offset) < (rank(winner[$1.element]!), $1.offset) }.map(\.element)
    for key in byScope {
        let cmd = winner[key]!
        if !cmd.available || shown.contains(cmd.id) { continue }
        let mineKeys = cmd.keys.filter { winner[$0] == cmd }.joined(separator: " · ")
        let line = SheetLine(key: mineKeys.isEmpty ? key : mineKeys, cmd: cmd)
        if cmd.scope == "global" { everywhere.append(line) } else { now.append(line) }
        shown.insert(cmd.id)
    }
    let notNow = here.filter { !shown.contains($0.id) && $0.scope != "global" }.map { SheetLine(key: $0.keys.joined(separator: " · "), cmd: $0) }
    return (now, everywhere, notNow)
}

/// One heading of the `?` sheet: an inner scope's (titled by what it acts on) or a `KeyGroup`'s.
public struct SheetSection: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case scope(String), group(KeyGroup) }
    public var kind: Kind
    public var lines: [SheetLine]
}

/// The sheet's sections in the order it shows them: the innermost scope first (the live order), then
/// the page's own keys by group (show, this branch, other branches, any left ungrouped), then the
/// keys that work anywhere, then the one collapsed move line (every motion, whatever its scope). Pairs (next ↔ previous) become one
/// line, and so do the numbered tabs; within a section the most used come first, then the order the sheet found them.
public func sheetSections(_ s: (now: [SheetLine], everywhere: [SheetLine], notNow: [SheetLine]), surface: String, live: [String]) -> [SheetSection] {
    let all = s.now + s.everywhere
    let byID = Dictionary(all.map { ($0.cmd.id, $0) }, uniquingKeysWith: { a, _ in a })
    var merged: [SheetLine] = []
    var used = Set<String>()
    for l in all where !used.contains(l.cmd.id) {
        used.insert(l.cmd.id)
        let partner = l.cmd.pair.flatMap { byID[$0] } ?? all.first { $0.cmd.pair == l.cmd.id }
        guard let p = partner, !used.contains(p.cmd.id) else { merged.append(l); continue }
        used.insert(p.cmd.id)
        var cmd = l.cmd
        cmd.verb = [l.cmd.verb, p.cmd.verb].compactMap { $0 }.joined(separator: "/")
        cmd.uses = l.cmd.uses + p.cmd.uses
        let first = { (x: SheetLine) in x.key.components(separatedBy: " · ").first ?? x.key }
        merged.append(SheetLine(key: "\(first(l)) \(first(p))", cmd: cmd))
    }
    let nth = merged.filter { $0.cmd.verb?.hasPrefix("nth-") == true }.sorted { ($0.cmd.verb ?? "") < ($1.cmd.verb ?? "") }
    if nth.count > 1, let at = merged.firstIndex(of: nth[0]) {
        var cmd = nth[0].cmd
        cmd.verb = "tabs"
        cmd.title = nth.map { $0.cmd.label ?? $0.cmd.title }.joined(separator: " · ")
        cmd.uses = nth.reduce(0) { $0 + $1.cmd.uses }
        let line = SheetLine(key: nth.map(\.key).joined(separator: " "), cmd: cmd)
        merged = merged.enumerated().compactMap { i, l in i == at ? line : nth.contains(l) ? nil : l }
    }
    let ownScope = surface
    func groupOf(_ l: SheetLine) -> KeyGroup? {
        let g = l.cmd.group.flatMap(KeyGroup.init(rawValue:))
        if g == .move { return .move }
        guard l.cmd.scope == ownScope || l.cmd.scope == "global" else { return nil }
        return g ?? (l.cmd.scope == "global" ? .anywhere : nil)
    }
    func ranked(_ ls: [SheetLine]) -> [SheetLine] {
        ls.enumerated().sorted { ($0.element.cmd.uses, -$0.offset) > ($1.element.cmd.uses, -$1.offset) }.map(\.element)
    }
    var out: [SheetSection] = []
    for scope in live where scope != ownScope && scope != "global" {
        let ls = merged.filter { $0.cmd.scope == scope && groupOf($0) == nil }
        if !ls.isEmpty { out.append(SheetSection(kind: .scope(scope), lines: ranked(ls))) }
    }
    let ungrouped = merged.filter { $0.cmd.scope == ownScope && groupOf($0) == nil }
    for g in [KeyGroup.show, .branch, .others] {
        let ls = merged.filter { groupOf($0) == g }
        if !ls.isEmpty { out.append(SheetSection(kind: .group(g), lines: ranked(ls))) }
    }
    if !ungrouped.isEmpty { out.append(SheetSection(kind: .scope(ownScope), lines: ranked(ungrouped))) }
    for g in [KeyGroup.anywhere, .move] {
        let ls = merged.filter { groupOf($0) == g }
        if !ls.isEmpty { out.append(SheetSection(kind: .group(g), lines: g == .move ? ls : ranked(ls))) }
    }
    return out
}
