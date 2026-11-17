import CanopyCore
import Foundation

struct CapturePlan {
    enum Action: Equatable {
        case key(String)
        case wait(UInt64)
        case draw(String)
        case state
        case terminalState
    }
    struct Shot: Equatable { let name: String; let address: String; let actions: [Action] }
    let shots: [Shot]
    let settle: UInt64

    init(_ config: AppConfig) throws {
        guard config.captureErrors.isEmpty else { throw Refusal(config.captureErrors.joined(separator: "; ")) }
        guard config.shootWidth.isFinite, config.shootHeight.isFinite,
              (1...8192).contains(config.shootWidth), (1...8192).contains(config.shootHeight),
              config.shootWidth * config.shootHeight <= 16_777_216 else { throw Refusal("capture size must fit within 8192 points and 16 megapoints") }
        settle = try Self.delay(config.dumpWait)
        guard !config.shots.isEmpty else { throw Refusal("capture needs at least one --shot name=/v2/route") }
        var names: Set<String> = []
        func reserve(_ name: String) throws {
            try Self.validateName(name)
            guard names.insert(name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))).inserted else { throw Refusal("duplicate capture name: \(name)") }
        }
        shots = try config.shots.map { spec in
            let parts = spec.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2 else { throw Refusal("capture wants name=/v2/route") }
            try reserve(parts[0])
            let tokens = parts[1].split(whereSeparator: \.isWhitespace).map(String.init)
            guard let address = tokens.first, Self.knownAddress(address) else { throw Refusal("unknown or missing capture route") }
            let actions = try tokens.dropFirst().map { token -> Action in
                if token.hasPrefix(">") { throw Refusal("terminal input is unavailable during capture") }
                if token.hasPrefix("~") {
                    guard let seconds = Double(token.dropFirst()) else { throw Refusal("invalid capture delay: \(token)") }
                    return .wait(try Self.delay(seconds))
                }
                if token.hasPrefix("!") {
                    let name = String(token.dropFirst()); try reserve(name)
                    return .draw(name)
                }
                if token == "?" { return .state }
                if token == "#" { return .terminalState }
                if token.hasPrefix("=") {
                    guard token.count > 1 else { throw Refusal("capture literal key is missing") }
                    return .key(String(token.dropFirst()))
                }
                return .key(token)
            }
            return Shot(name: parts[0], address: address, actions: actions)
        }
    }

    static func delay(_ seconds: Double) throws -> UInt64 {
        guard seconds.isFinite, (0...60).contains(seconds) else { throw Refusal("capture delays must be between 0 and 60 seconds") }
        return UInt64(seconds * 1_000_000_000)
    }

    static func validateName(_ name: String) throws {
        guard !name.isEmpty, ![".", ".."].contains(name), name.utf8.count <= 200,
              !name.contains("/"), !name.contains("\\"), !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw Refusal("capture names must be a single nonempty filename component")
        }
    }

    static func knownAddress(_ address: String) -> Bool {
        guard address.hasPrefix("/v2"), let supplied = URLComponents(string: address), supplied.fragment == nil,
              let wanted = supplied.percentEncodedPath.removingPercentEncoding else { return false }
        let route = Route(address)
        let scopes = (supplied.queryItems ?? []).filter { ["base", "commit"].contains($0.name) }
        if !scopes.isEmpty {
            guard case .review(_, _, let stretch) = route, scopes.count == 1,
                  let scope = scopes.first, let value = scope.value, !value.isEmpty, stretch == value else { return false }
            if scope.name == "base", !Route.presets.contains(value) { return false }
            if scope.name == "commit" {
                let ends = value.components(separatedBy: "..")
                guard (1...2).contains(ends.count), ends.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber } }) else { return false }
            }
        }
        let parsed = route.path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? ""
        let actual = parsed.removingPercentEncoding ?? parsed
        return wanted.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == actual.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

struct CaptureOutput {
    let directory: URL

    init(_ path: String) throws {
        guard !path.isEmpty else { throw Refusal("capture output directory is missing") }
        directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func writePNG(_ data: Data?, named name: String) throws -> URL {
        try CapturePlan.validateName(name)
        guard let data, !data.isEmpty else { throw Refusal("capture PNG encoding failed") }
        let url = directory.appendingPathComponent("\(name).png")
        try data.write(to: url, options: .atomic)
        return url
    }
}
