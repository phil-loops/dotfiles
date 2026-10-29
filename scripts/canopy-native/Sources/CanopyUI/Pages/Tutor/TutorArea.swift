import CanopyCore
import SwiftUI

/// The tutor (/v2/tutor[/<session>]): the concept graph, sessions, the Socratic turn stream
/// (POST /tutor, SSE via Transport.streamPost), the code pane, the simulator.
enum TutorArea: PageArea {
    static let name = "tutor"
    static func install(_ app: AppModel) { app.addSurface(TutorSurface()) }
}

struct TutorSurface: PlaceholderSurface {
    let surfaceID = "tutor"
    func placeholder(_ app: AppModel, route: Route) -> Placeholder {
        Placeholder(title: "Tutor", area: "tutor",
                    sources: ["Tutor.tsx", "tutoring.ts", "lesson.ts", "TutorSim.tsx", "sim.ts", "simScenarios.ts", "commands/tutor.ts"],
                    notes: ["session: \(route.arg.isEmpty ? "home" : route.arg)"])
    }
}
