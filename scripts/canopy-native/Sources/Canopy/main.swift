import CanopyCore
import CanopyUI

let config = AppConfig.parse(Array(CommandLine.arguments.dropFirst()))
MainActor.assumeIsolated {
    if config.dump {
        Dump.run(config)
    } else {
        CanopyApp.launch(config)
    }
}
