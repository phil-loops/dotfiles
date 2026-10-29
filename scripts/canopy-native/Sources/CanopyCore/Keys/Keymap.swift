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
    public init(id: String, title: String, scope: String, keys: [String], available: Bool) {
        self.id = id; self.title = title; self.scope = scope; self.keys = keys; self.available = available
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
