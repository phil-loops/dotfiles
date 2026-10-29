import Foundation

/// The navigation keys NAV.md §5 decided for commands other areas own. An area registering one of
/// these ids binds exactly these keys (ShellTests `reservedNavKeysAreHonored`), so use
/// `NavKeys.keys(id)` in your `Command(keys:)`. Commands in `jumps` record a jumplist entry
/// before they run — the registry sets `recordsJump` for them, you don't have to.
public enum NavKeys {
    public static let reserved: [String: [String]] = [
        // Forests (A): `f` is the label layer now, so focusing a forest moves to `F`
        "project.focus": ["F"],
        "forests.find": ["space f"],
        "forest.find": ["space f"],
        "forest.branch.next": ["J"], "forest.branch.prev": ["K"],
        "forest.parent": ["g k"], "forest.child": ["g j"], "forest.root": ["g K"], "forest.tip": ["g J"],
        // Review (B): `v` is select everywhere; `m` marks viewed and advances, `M` unmarks; `/` is search
        "review.viewed": ["m"], "review.unviewed": ["M"],
        "review.filter": ["space f"],
        "review.hunk.next": ["}"], "review.hunk.prev": ["{"],
        "review.file.next": ["]"], "review.file.prev": ["["],
        "review.thread.next": ["n"], "review.thread.prev": ["N"],
        "review.branch.next": ["J"], "review.branch.prev": ["K"],
        "review.parent": ["g k"], "review.child": ["g j"], "review.root": ["g K"], "review.tip": ["g J"],
    ]

    /// What records a jump (NAV.md §4.4), beyond every page change (the router records those) and the
    /// shell's own label/picker picks: `g`-gotos, J/K and the DAG moves, ]/[, n/N, gg/G.
    public static let jumps: Set<String> = [
        "cursor.top", "cursor.bottom",
        "forest.branch.next", "forest.branch.prev", "forest.parent", "forest.child", "forest.root", "forest.tip",
        "review.branch.next", "review.branch.prev", "review.parent", "review.child", "review.root", "review.tip",
        "review.file.next", "review.file.prev", "review.thread.next", "review.thread.prev",
        "review.top", "review.bottom",
    ]

    /// The keys NAV.md decided for `id` ([] when it decided none).
    public static func keys(_ id: String) -> [String] { reserved[id] ?? [] }
}
