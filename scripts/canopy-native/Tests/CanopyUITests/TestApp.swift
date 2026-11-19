import CanopyCore
import CanopyTestSupport
import Foundation
@testable import CanopyUI

/// The one way a test builds an app: no telemetry, preferences in memory (nothing reaches the
/// machine — ComposerTests had left 1,699 preference files behind), and a clock that moves only
/// when the test advances it (`app.clock`), so no assertion races a real timer (2026-11-18).
@MainActor func testApp(config: AppConfig, port: Int, protocolClasses: [AnyClass]? = nil) -> AppModel {
    AppModel(config: config, port: port, telemetry: false, protocolClasses: protocolClasses, defaults: MemoryDefaults(),
             scheduler: ManualScheduler())
}

extension AppModel {
    /// A test app's clock: `app.clock.advance(by: 4)` is four seconds passing.
    @MainActor var clock: ManualScheduler { scheduler as! ManualScheduler }
}
