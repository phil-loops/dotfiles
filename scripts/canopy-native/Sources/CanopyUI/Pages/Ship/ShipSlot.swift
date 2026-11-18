import CanopyCore

/// What fills the one place beneath the ship line: the branch's line says where it stands, and this slot holds the
/// single thing that needs you, by priority. A finished action leaves nothing here unless it left you something to do.
enum ShipSlot: Equatable {
    /// the sync's steps: a decision on dirt, a hand-off, a failure, or the motion in flight
    case motion
    /// the gates run on this tree: asked for, failed or stopped, or running
    case gates
    /// a diverged branch's force guards
    case guards
    /// the left tree's checks while the new tree's run readies, dimmed
    case previousGates
    case none

    struct Facts: Equatable {
        var motion: SyncPhase?
        var gatesAsked = false
        var gatesFailed = false
        var gatesRunning = false
        var guards = false
        var previousGates = false
    }

    static func pick(_ f: Facts) -> ShipSlot {
        if f.motion == .dirt { return .motion }
        if f.gatesAsked { return .gates }
        if f.motion != nil { return .motion }
        if f.gatesFailed { return .gates }
        if f.guards { return .guards }
        if f.gatesRunning { return .gates }
        if f.previousGates { return .previousGates }
        return .none
    }
}
