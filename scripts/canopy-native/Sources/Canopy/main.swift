import CanopyCore
import CanopyUI
import Foundation

let config = AppConfig.parse(Array(CommandLine.arguments.dropFirst()))
MainActor.assumeIsolated {
    if !config.shootDir.isEmpty {
        Shoot.run(config)
    } else if config.dump {
        Dump.run(config)
    } else {
        // Show is canopy's one window and the only one that follows new builds; a window here would go stale.
        let show = Process()
        show.executableURL = URL(fileURLWithPath: NSHomeDirectory() + "/.dotfiles/scripts/show")
        show.arguments = ["--canopy", config.address ?? ""]
        try? show.run()
        show.waitUntilExit()
        exit(show.terminationStatus)
    }
}
