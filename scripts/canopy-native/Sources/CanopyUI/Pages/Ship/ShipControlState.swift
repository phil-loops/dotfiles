import CanopyCore

struct ShipControlState: Equatable {
    let enabled: Bool
    let reason: String?

    /// The push button: enabled when `p` has a route; otherwise the branch's situation, in its one sentence, says why.
    static func push(route: String?, situation: String?) -> Self {
        if route == "branch.proof" { return Self(enabled: false, reason: "proof branches do not push") }
        if route != nil { return Self(enabled: true, reason: nil) }
        return Self(enabled: false, reason: situation ?? "branch details unavailable")
    }
}
