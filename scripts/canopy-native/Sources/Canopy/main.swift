import CanopyCore
import CanopyUI
import Foundation

let config = AppConfig.parse(Array(CommandLine.arguments.dropFirst()))
MainActor.assumeIsolated {
    if let error = config.launchError {
        FileHandle.standardError.write(Data("canopy: \(error)\n".utf8))
        exit(64)
    }
    if config.bench {
        Bench.run(config)
    } else if config.shootRequested || !config.shootDir.isEmpty {
        Shoot.run(config)
    } else if config.dump {
        Dump.run(config)
    } else {
        FileHandle.standardError.write(Data("canopy: this binary only runs --shoot, --bench or --dump; canopy itself is Show's ⌘6 (run `canopy`)\n".utf8))
        exit(64)
    }
}
