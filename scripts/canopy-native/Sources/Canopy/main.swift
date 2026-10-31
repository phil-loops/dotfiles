import CanopyCore
import CanopyUI

let config = AppConfig.parse(Array(CommandLine.arguments.dropFirst()))
MainActor.assumeIsolated {
    if !config.shootDir.isEmpty {
        Shoot.run(config)
    } else if config.dump {
        Dump.run(config)
    } else {
        CanopyApp.launch(config)
    }
}
