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
/// false, and the caller hands it to the focused text field. Insert routes `↵` by the field's kind
/// (`fieldLines`): it finishes a one-line field, and in a many-line box it's the box's own newline —
/// there only `⌃↵` sends, so sending is always deliberate where the frequent act is a new line. The UI layer turns NSEvents into key
/// names (`KeyName`); everything else is here, so it's testable without a window.
@MainActor
@Observable
public final class KeyEngine {
    public private(set) var mode: KeyMode = .normal
    public private(set) var layer: KeyMode?
    /// The half-typed prefix ("space", "g") which-key and the statusline show; "" when none.
    public private(set) var pendingKeys = ""
    /// The kind of field insert mode is typing into; back to `.single` whenever insert ends.
    public var fieldLines: FieldLines = .single

    /// Mode or layer changed (from, to): the shell resigns a text field on leaving insert, drops
    /// the selection anchor on leaving select, closes the picker's state with its layer.
    @ObservationIgnored public var onChange: ((_ from: KeyMode, _ to: KeyMode) -> Void)?
    /// A layer that reads raw keys rather than a keymap (the label layer: whatever label you type).
    /// It sees every key but esc while it's the active layer; true means it took the key.
    @ObservationIgnored public var layerKeys: [KeyMode: (String) -> Bool] = [:]
    /// True while esc runs a page's own back-out: esc only ever cancels (NAV.md §4.5), so the
    /// shell refuses any page change made meanwhile.
    public private(set) var cancelling = false
    public static let nothingToCancel = "- goes up · C-o goes back"

    /// Every finished key sequence as the verb it is here (the keytutor watches these).
    @ObservationIgnored public var onVerb: ((VerbEvent) -> Void)?
    /// While this answers an engine (the keytutor's practice app), every key goes there instead, and
    /// `afterNested` hears each one with what the nested engine did with it.
    @ObservationIgnored public var nested: (() -> KeyEngine?)?
    @ObservationIgnored public var afterNested: ((_ key: String, _ took: Bool) -> Void)?
    /// Whether the last esc cancelled something (a chord, a layer, a mode, a page's own back-out
    /// that went through) rather than finding nothing to cancel.
    public private(set) var lastEscCancelled = false

    @ObservationIgnored private let registry: CommandRegistry
    @ObservationIgnored private let runner: Runner
    @ObservationIgnored private var keymap = Keymap([])
    @ObservationIgnored private var builtFor = -1

    public init(registry: CommandRegistry, runner: Runner) {
        self.registry = registry
        self.runner = runner
    }

    /// The engine keys really reach: a nested one while it's there, else this.
    public var innermost: KeyEngine { nested?()?.innermost ?? self }

    /// The live keymap: the layer if one is up, else the mode.
    public var active: KeyMode { layer ?? mode }
    public var textEntry: Bool { KeyMode.textEntry.contains(active) }

    // ── modes and layers ──

    public func setMode(_ m: KeyMode) {
        guard m != mode else { return }
        let from = active
        if mode == .insert { fieldLines = .single }
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
        let from = active
        if !pendingKeys.isEmpty {
            reset()
            return cancelled(from)
        }
        if layer != nil {
            closeLayer()
            return cancelled(from)
        }
        if mode != .normal {
            setMode(.normal)
            return cancelled(from)
        }
        cancelling = true
        defer { cancelling = false }
        let took = feed("esc")
        lastEscCancelled = took && runner.fired?.ok != false
        if !lastEscCancelled { runner.say(Self.nothingToCancel) }
        return took
    }

    private func cancelled(_ from: KeyMode) -> Bool {
        lastEscCancelled = true
        onVerb?(VerbEvent(verb: .cancel, command: nil, keys: "esc", ok: true, mode: from))
        return true
    }

    // ── keys ──

    private func rebuild() {
        guard builtFor != registry.keysVersion else { return }
        builtFor = registry.keysVersion
        keymap = Keymap(registry.commands.flatMap { c in
            c.modes.compactMap { m in
                c.keysByMode[m].flatMap { $0.isEmpty ? nil : KeyBinding(id: c.id, keys: $0, scope: c.scope.rawValue, modes: [m.rawValue]) }
            }
        })
    }

    /// Feed one key name. Returns true when the key was consumed (ran a command, extended or ended
    /// a chord, backed out) — the caller then swallows the event; false hands it on (to a text field).
    @discardableResult
    public func handle(_ key: String) -> Bool {
        if let n = nested?() {
            let took = n.handle(key)
            afterNested?(key, took)
            return took || key == "esc"
        }
        if key == "esc" { return backOut() }
        if key == "ret", active == .insert, fieldLines == .multi {
            reset()
            onVerb?(VerbEvent(verb: .newline, command: nil, keys: key, ok: true, mode: .insert))
            return false
        }
        return feed(key)
    }

    private func feed(_ key: String) -> Bool {
        if let raw = layerKeys[active] { return raw(key) }
        rebuild()
        let mode = active
        let seq = pendingKeys.isEmpty ? key : "\(pendingKeys) \(key)"
        let scopes = (runner.context?.liveScopes() ?? [.global]).map(\.rawValue)
        let fed = keymap.feed(key, scopes: scopes, mode: mode.rawValue)
        // a prefix (space, g) waits for its next key as long as it takes, like Helix
        if case .pending(let prefix) = fed {
            pendingKeys = prefix
            if prefix == registry.verbKeys.leader { onVerb?(VerbEvent(verb: .leader, command: nil, keys: prefix, ok: true, mode: mode)) }
            return true
        }
        let wasPending = !pendingKeys.isEmpty
        pendingKeys = ""
        if case .run(let id) = fed {
            runner.dispatch(id, via: .key)
            if let onVerb {
                let verb = registry.command(id)?.verbs.first { registry.verbKeys.of($0, in: mode).contains(seq) }
                let ok = runner.fired.map { $0.id != id || $0.ok } ?? true
                onVerb(VerbEvent(verb: verb, command: id, keys: seq, ok: ok, mode: mode))
            }
            return true
        }
        if let onVerb {
            let verb = Verb.allCases.first { registry.verbKeys.of($0, in: mode).contains(seq) }
            // typing into a field isn't an attempt at anything
            if verb != nil || !mode.takesText { onVerb(VerbEvent(verb: verb, command: nil, keys: seq, ok: false, mode: mode)) }
        }
        return wasPending
    }

    /// Drop a half-typed chord (a click anywhere does too).
    public func reset() {
        keymap.reset()
        pendingKeys = ""
    }

    /// What can follow the pending prefix here (WhichKey.tsx), narrowest scope's meaning winning:
    /// each row says the verb it is ("m · mark") with the page's own title after it; a key under
    /// the page's leader has no verb, only its title.
    public func whichKeyRows() -> [WhichKeyRow] {
        let prefix = pendingKeys
        guard !prefix.isEmpty, let ctx = runner.context else { return [] }
        let live = ctx.liveScopes()
        func rank(_ s: Scope) -> Int { s == .global ? live.count : (live.firstIndex(of: s) ?? .max) }
        var seen = Set<String>()
        var rows: [WhichKeyRow] = []
        let vk = registry.verbKeys
        let cmds = registry.commands
            .filter { $0.modes.contains(active) && ($0.scope == .global || live.contains($0.scope)) && ($0.available?(ctx.target(for: $0.scope)) ?? true) }
            .enumerated().sorted { (rank($0.element.scope), $0.offset) < (rank($1.element.scope), $1.offset) }.map(\.element)
        for c in cmds {
            for k in c.keysByMode[active] ?? [] where k.hasPrefix(prefix + " ") {
                let rest = String(k.dropFirst(prefix.count + 1))
                let verb = c.verbs.first { vk.of($0, in: active).contains(k) }
                if seen.insert(rest).inserted { rows.append(WhichKeyRow(key: rest, verb: verb?.name, what: shortTitle(c.title))) }
            }
        }
        // a run of numbered slots (g 1 … g 9) reads as one row
        let digits = rows.filter { $0.key.count == 1 && $0.key.first!.isNumber }
        if digits.count > 2, let one = digits.min(by: { $0.key < $1.key }), let top = digits.max(by: { $0.key < $1.key }) {
            rows.removeAll { $0.key.count == 1 && $0.key.first!.isNumber }
            rows.append(WhichKeyRow(key: "\(one.key)–\(top.key)", verb: one.verb.map { $0.replacingOccurrences(of: "1", with: "N") },
                                    what: one.what.replacingOccurrences(of: one.key, with: "N")))
        }
        return rows.sorted { a, b in
            let la = a.key.lowercased(), lb = b.key.lowercased()
            return la != lb ? la < lb : a.key < b.key
        }
    }

    /// True while the half-typed prefix is the page's leader: which-key titles it "this page's keys".
    public var pendingIsLeader: Bool { pendingKeys == registry.verbKeys.leader }

    /// What `:` can run here, best match first: every live, available command that doesn't need an
    /// argument from another view — so nothing is keyless *and* unreachable.
    public func completions(_ typed: String) -> [Command] {
        guard let ctx = runner.context else { return [] }
        let live = ctx.liveScopes()
        let cmds = registry.commands.filter {
            !$0.needsArg && live.contains($0.scope) && ($0.available?(ctx.target(for: $0.scope)) ?? true)
        }
        let want = typed.trimmingCharacters(in: .whitespaces)
        // "<id> <argument>": the command named exactly, with what follows as its argument
        if let sp = want.firstIndex(of: " "), let named = cmds.first(where: { $0.id == want[..<sp] }) { return [named] }
        if let exact = cmds.first(where: { $0.id == want }) { return [exact] + cmds.filter { $0.id != want && ranked([$0], want, Self.text).count == 1 } }
        return ranked(cmds, want, Self.text)
    }

    private static func text(_ c: Command) -> String { "\(c.id) \(c.title)" }
}

/// A finished key sequence as the verb it is in the mode it was typed in: the command it ran (nil
/// when nothing here implements it) and whether that went through.
public struct VerbEvent: Equatable, Sendable {
    public var verb: Verb?
    public var command: String?
    public var keys: String
    public var ok: Bool
    public var mode: KeyMode
    public init(verb: Verb?, command: String?, keys: String, ok: Bool, mode: KeyMode) {
        self.verb = verb; self.command = command; self.keys = keys; self.ok = ok; self.mode = mode
    }
}

/// What a text field holds: one line (`↵` finishes it) or many (`↵` is a newline; `⌃↵` sends).
public enum FieldLines: Sendable, Equatable {
    case single, multi
}

/// One which-key line: the key after the prefix, the verb it is (nil under the leader), the page's title.
public struct WhichKeyRow: Equatable, Sendable {
    public var key: String
    public var verb: String?
    public var what: String
    public init(key: String, verb: String?, what: String) { self.key = key; self.verb = verb; self.what = what }
    /// "m · mark — mark viewed and go on", or the bare title under the leader
    public var line: String { verb.map { "\($0) — \(what)" } ?? what }
}
