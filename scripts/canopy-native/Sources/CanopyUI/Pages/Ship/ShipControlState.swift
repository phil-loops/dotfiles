import CanopyCore

struct ShipControlState: Equatable {
    let enabled: Bool
    let reason: String?

    static func push(_ branch: Branch, route: String?, contextKnown: Bool, checking: Bool = false) -> Self {
        if route == "branch.proof" { return Self(enabled: false, reason: "proof branches do not push") }
        if route != nil { return Self(enabled: true, reason: nil) }
        if branch.pending != nil { return Self(enabled: false, reason: "branch operation pending") }
        if !contextKnown { return Self(enabled: false, reason: "branch details unavailable") }
        if branch.commits == 0 { return Self(enabled: false, reason: "no changes to push") }
        if branch.diverged {
            return Self(enabled: false, reason: checking ? "checking origin's copy…" : "origin replacement unavailable")
        }
        if branch.ahead == 0 && (branch.pushed == .synced || branch.pushed == .ahead) {
            return Self(enabled: false, reason: "up to date on origin")
        }
        return Self(enabled: false, reason: "push unavailable")
    }
}
