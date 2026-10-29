import Foundation
import Observation

/// The modal key machine — the spine of the app. Every key goes mode → keymap → command:
///
///   * a **mode** (normal, insert, select, command) and, on top of it, an optional transient
///     **layer** (the space menu, the `?` sheet, the picker) — whichever is innermost names the
///     live keymap (`active`);
///   * a half-typed chord (`space`, `g`, `C-w`) is pending until its next key; which-key shows it;
///   * `esc` always backs out exactly one level, innermost first: the pending chord → the layer →
///     the mode (back to normal) → the page's own back-out (`esc` bound in normal: overlay.close,
///     review.back, wiki.back, …).
///
/// In text-entry modes (insert, command, menu, picker) a key nobody bound in that mode returns
/// false, and the caller hands it to the focused text field. The UI layer turns NSEvents into key
/// names (`KeyName`); everything else is here, so it's testable without a window.
@MainActor
@Observable
public final class KeyEngine {
    public private(set) var mode: KeyMode = .normal
    public private(set) var layer: KeyMode?
    /// The half-typed prefix ("space", "g") which-key and the statusline show; "" when none.
    public private(set) var pendingKeys = ""

    /// Mode or layer changed (from, to): the shell resigns a text field on leaving insert, drops
    /// the selection anchor on leaving select, closes the picker's state with its layer.
    @ObservationIgnored public var onChange: ((_ from: KeyMode, _ to: KeyMode) -> Void)?

    @ObservationIgnored private let registry: CommandRegistry
    @ObservationIgnored private let runner: Runner
    @ObservationIgnored private var keymap = Keymap([])
    @ObservationIgnored private var builtFor = -1

    public init(registry: CommandRegistry, runner: Runner) {
        self.registry = registry
        self.runner = runner
    }

    /// The live keymap: the layer if one is up, else the mode.
    public var active: KeyMode { layer ?? mode }
    public var textEntry: Bool { KeyMode.textEntry.contains(active) }

    // ── modes and layers ──

    public func setMode(_ m: KeyMode) {
        guard m != mode else { return }
        let from = active
        mode = m
        keymap.reset()
        pendingKeys = ""
        if from != active { onChange?(from, active) }
    }

    public func openLayer(_ l: KeyMode) {
        guard layer != l else { return }
        let from = active
        layer = l
        keymap.reset()
        pendingKeys = ""
        onChange?(from, l)
    }

    public func closeLayer() {
        guard let l = layer else { return }
        layer = nil
        keymap.reset()
        pendingKeys = ""
        onChange?(l, active)
    }

    /// One level out (see the type's doc). Returns false only when nothing at any level took it.
    @discardableResult
    public func backOut() -> Bool {
        if !pendingKeys.isEmpty {
            reset()
            return true
        }
        if layer != nil {
            closeLayer()
            return true
        }
        if mode != .normal {
            setMode(.normal)
            return true
        }
        return feed("esc")
    }

    // ── keys ──

    private func rebuild() {
        guard builtFor != registry.keysVersion else { return }
        builtFor = registry.keysVersion
        keymap = Keymap(registry.commands.filter { !$0.keys.isEmpty }.map {
            KeyBinding(id: $0.id, keys: $0.keys, scope: $0.scope.rawValue, modes: $0.modes.map(\.rawValue))
        })
    }

    /// Feed one key name. Returns true when the key was consumed (ran a command, extended or ended
    /// a chord, backed out) — the caller then swallows the event; false hands it on (to a text field).
    @discardableResult
    public func handle(_ key: String) -> Bool {
        if key == "esc" { return backOut() }
        return feed(key)
    }

    private func feed(_ key: String) -> Bool {
        rebuild()
        let scopes = (runner.context?.liveScopes() ?? [.global]).map(\.rawValue)
        let fed = keymap.feed(key, scopes: scopes, mode: active.rawValue)
        // a prefix (space, g) waits for its next key as long as it takes, like Helix
        if case .pending(let prefix) = fed {
            pendingKeys = prefix
            return true
        }
        let wasPending = !pendingKeys.isEmpty
        pendingKeys = ""
        if case .run(let id) = fed {
            runner.dispatch(id, via: .key)
            return true
        }
        return wasPending
    }

    /// Drop a half-typed chord (a click anywhere does too).
    public func reset() {
        keymap.reset()
        pendingKeys = ""
    }

    /// What can follow the pending prefix here (WhichKey.tsx), narrowest scope's meaning winning.
    public func whichKeyRows() -> [(key: String, what: String)] {
        let prefix = pendingKeys
        guard !prefix.isEmpty, let ctx = runner.context else { return [] }
        let live = ctx.liveScopes()
        func rank(_ s: Scope) -> Int { s == .global ? live.count : (live.firstIndex(of: s) ?? .max) }
        var seen = Set<String>()
        var rows: [(key: String, what: String)] = []
        let cmds = registry.commands
            .filter { $0.modes.contains(active) && ($0.scope == .global || live.contains($0.scope)) && ($0.available?(ctx.target(for: $0.scope)) ?? true) }
            .enumerated().sorted { (rank($0.element.scope), $0.offset) < (rank($1.element.scope), $1.offset) }.map(\.element)
        for c in cmds {
            for k in c.keys where k.hasPrefix(prefix + " ") {
                let rest = String(k.dropFirst(prefix.count + 1))
                if seen.insert(rest).inserted { rows.append((rest, shortTitle(c.title))) }
            }
        }
        return rows.sorted { a, b in
            let la = a.key.lowercased(), lb = b.key.lowercased()
            return la != lb ? la < lb : a.key < b.key
        }
    }

    /// What `:` can run here, best match first: every live, available command that doesn't need an
    /// argument from another view — so nothing is keyless *and* unreachable.
    public func completions(_ typed: String) -> [Command] {
        guard let ctx = runner.context else { return [] }
        let live = ctx.liveScopes()
        let cmds = registry.commands.filter {
            !$0.needsArg && live.contains($0.scope) && ($0.available?(ctx.target(for: $0.scope)) ?? true)
        }
        let want = typed.trimmingCharacters(in: .whitespaces)
        if let exact = cmds.first(where: { $0.id == want }) { return [exact] + cmds.filter { $0.id != want && ranked([$0], want, Self.text).count == 1 } }
        return ranked(cmds, want, Self.text)
    }

    private static func text(_ c: Command) -> String { "\(c.id) \(c.title)" }
}
