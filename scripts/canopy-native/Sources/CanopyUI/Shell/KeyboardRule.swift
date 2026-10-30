import CanopyCore

/// The mouseless rule, checkable: every command is reachable by key. Each area's tests call
/// `KeyboardRule.violations(app) { $0.hasPrefix("myarea.") }` and expect none.
///
///   * a command with no key is runnable from `:` unless it's `needsArg` — those are reached only
///     through a keyed route (pane.open → primary), the menu, or the picker that supplies the
///     argument; mark a command `needsArg` only when that's true;
///   * its scope must be live on some page (or global), or neither keys nor `:` ever reach it;
///   * in a text-entry mode (insert, command, menu, picker) it may not bind a bare printable key —
///     that key would never reach the field.
@MainActor
public enum KeyboardRule {
    public static func violations(_ app: AppModel, _ include: (String) -> Bool = { _ in true }) -> [String] {
        let onPages = Set(app.registry.surfaceScopes.values.flatMap { $0 } + Surface.all.map { Scope(rawValue: $0.id) } + [.global])
        var out: [String] = []
        for c in app.registry.commands where include(c.id) {
            // reached through whatever keyed route, menu or picker supplies its argument
            if c.keys.isEmpty && c.needsArg { continue }
            if !onPages.contains(c.scope) { out.append("\(c.id): scope \(c.scope.rawValue) is on no page — unreachable") }
            for m in c.modes where KeyMode.textEntry.contains(m) {
                for k in c.keysByMode[m] ?? [] where k.count == 1 {
                    out.append("\(c.id): binds \"\(k)\" in \(m.rawValue) mode — typing could never reach the field")
                }
            }
        }
        return out
    }
}
