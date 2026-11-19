import CanopyCore
import CanopyTestSupport
import Foundation
@testable import CanopyUI

/// The one way a test builds an app: no telemetry, and preferences in memory, so nothing a test
/// writes reaches the machine (ComposerTests had left 1,699 preference files behind, 2026-11-18).
@MainActor func testApp(config: AppConfig, port: Int, protocolClasses: [AnyClass]? = nil) -> AppModel {
    AppModel(config: config, port: port, telemetry: false, protocolClasses: protocolClasses, defaults: MemoryDefaults())
}
