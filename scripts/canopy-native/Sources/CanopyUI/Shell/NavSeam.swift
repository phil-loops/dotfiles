import CanopyCore
import Foundation
import Observation

// Stand-in for area N's navigation core (NAV.md §7) — the names and shapes the forests area builds
// against. Dropped on integration in favour of canopy-native/nav's definitions.

/// One thing the label layer can point at: a row or a control in a pane, and what picking it does.
public struct Target: Equatable {
    public var pane: String
    /// a row key ("b:<id>") or a control's own key ("forest.integrate:<pid>")
    public var key: String
    /// where it sits on screen, once drawn (the label renderer fills this from the view)
    public var rect: CGRect?
    /// what picking it runs — the same as `ret` on it
    public var primary: RouteTo?

    public init(pane: String, key: String, rect: CGRect? = nil, primary: RouteTo? = nil) {
        self.pane = pane; self.key = key; self.rect = rect; self.primary = primary
    }

    public static func == (a: Target, b: Target) -> Bool {
        a.pane == b.pane && a.key == b.key && a.rect == b.rect && a.primary?.id == b.primary?.id && a.primary?.target == b.primary?.target
    }
}

public extension KeyMode {
    /// the label layer: every visible target wears a home-row label; one press picks
    static let labels: KeyMode = "labels"
}

/// A place the jumplist can restore exactly (NAV.md §4.4).
public struct Place: Equatable {
    public var surface: String
    public var arg: String
    public var cursorKey: String?
    public var tab: String?
    public var base: String?
    public var scroll: Double?

    public init(surface: String, arg: String, cursorKey: String? = nil, tab: String? = nil, base: String? = nil, scroll: Double? = nil) {
        self.surface = surface; self.arg = arg; self.cursorKey = cursorKey; self.tab = tab; self.base = base; self.scroll = scroll
    }
}

/// The app-wide jumplist: stack semantics, a new jump truncates forward, identical neighbours collapse.
@MainActor
@Observable
public final class Jumplist {
    public private(set) var back: [Place] = []
    public private(set) var fwd: [Place] = []

    public init() {}

    public func record(_ p: Place) {
        if back.last != p { back = Array((back + [p]).suffix(100)) }
        fwd = []
    }
}

public extension AppModel {
    var jumplist: Jumplist { state { Jumplist() } }
}
