import CoreGraphics
import Foundation

/// The label layer's assignment (NAV.md §4.3), pure: home-row labels given out by on-screen
/// position, computed once when the layer opens. One character when there are ≤ 10 targets;
/// otherwise the first character names the pane (so the eye narrows to a pane first, like leap's
/// preview) and the rest name the target within it — so a pane's labels don't move when another
/// pane's targets change.
public enum Labels {
    /// The home row, then the row above it.
    public static let alphabet: [Character] = Array("asdfghjkl;qwertyuiop")
    public static let singleMax = 10

    /// Where one target sits: its pane, its key, its on-screen origin (top-left, y down).
    public struct Spot: Equatable, Sendable {
        public var pane: String
        public var key: String
        public var x: Double
        public var y: Double
        public init(pane: String, key: String, x: Double, y: Double) { self.pane = pane; self.key = key; self.x = x; self.y = y }
    }

    /// One label per spot, in the order given (nil past the alphabet's reach). `paneOrder` ranks
    /// panes (left to right on the grid); panes not in it follow, by their topmost-leftmost target.
    public static func assign(_ spots: [Spot], paneOrder: [String] = []) -> [String?] {
        let panes = order(spots, paneOrder)
        let byPane = Dictionary(grouping: spots.indices, by: { spots[$0].pane }).mapValues { ix in
            ix.sorted { (spots[$0].y, spots[$0].x, $0) < (spots[$1].y, spots[$1].x, $1) }
        }
        var out = [String?](repeating: nil, count: spots.count)
        if spots.count <= singleMax {
            var n = 0
            for p in panes { for i in byPane[p] ?? [] { out[i] = String(alphabet[n]); n += 1 } }
            return out
        }
        let base = alphabet.count
        for (pi, p) in panes.enumerated() where pi < base {
            let ix = byPane[p] ?? []
            var width = 1
            while pow(Double(base), Double(width)) < Double(ix.count) { width += 1 }
            for (n, i) in ix.enumerated() {
                var digits: [Character] = []
                var v = n
                for _ in 0..<width { digits.insert(alphabet[v % base], at: 0); v /= base }
                out[i] = String(alphabet[pi]) + String(digits)
            }
        }
        return out
    }

    static func order(_ spots: [Spot], _ paneOrder: [String]) -> [String] {
        var firsts: [String: (Double, Double)] = [:]
        for s in spots {
            if let f = firsts[s.pane], f <= (s.y, s.x) { continue }
            firsts[s.pane] = (s.y, s.x)
        }
        let known = paneOrder.filter { firsts[$0] != nil }
        let rest = firsts.keys.filter { !known.contains($0) }.sorted { (firsts[$0]!.0, firsts[$0]!.1, $0) < (firsts[$1]!.0, firsts[$1]!.1, $1) }
        return known + rest
    }
}

/// One thing the label layer can point at (NAV.md §7 `targets()`): a row, a tab, a file, a hunk, a
/// button. `run` is what picking it does; nil means "the same as `ret` on that row" — the cursor
/// moves there and the surface's `primary(for:)` runs.
public struct LabelTarget {
    /// the pane it belongs to — a `Pane.id` for rows; any group name ("tabs") for free targets
    public var pane: String
    /// a row key for rows ("b:loops:x"); any stable key otherwise ("tab:files")
    public var key: String
    /// on screen, in window (SwiftUI .global) coordinates
    public var rect: CGRect
    /// what `/` (search on page) matches against
    public var title: String
    public var run: RouteTo?

    public init(pane: String, key: String, rect: CGRect, title: String = "", run: RouteTo? = nil) {
        self.pane = pane; self.key = key; self.rect = rect; self.title = title; self.run = run
    }

    public var spot: Labels.Spot { Labels.Spot(pane: pane, key: key, x: rect.minX, y: rect.minY) }
}
