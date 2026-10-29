import CanopyCore
import SwiftUI

/// The machine (/v2/machine: previews, servers, footprint, logs; the `procs` pulse) and the
/// dashboard (/v2/dashboard: telemetry vs budgets).
enum MachineArea: PageArea {
    static let name = "machine"

    static func install(_ app: AppModel) {
        app.addSurface(MachineSurface())
        app.addSurface(DashboardSurface())
    }
}

struct MachineSurface: PlaceholderSurface {
    let surfaceID = "machine"
    func placeholder(_ app: AppModel, route: Route) -> Placeholder {
        Placeholder(title: "Machine", area: "machine", sources: ["Machine.tsx", "workstation.ts", "commands/machine.ts"],
                    notes: ["servers come from GET /previews, /footprint; moves from the /events `procs` pulse (AppModel.pulse)"])
    }
}

struct DashboardSurface: PlaceholderSurface {
    let surfaceID = "dashboard"
    func placeholder(_ app: AppModel, route: Route) -> Placeholder {
        Placeholder(title: "Dashboard", area: "machine", sources: ["Dashboard.tsx", "budgets.ts", "telemetry.ts", "commands/app.ts (dashboard.range)"],
                    notes: ["reads GET /telemetry/summary?days=N"])
    }
}
