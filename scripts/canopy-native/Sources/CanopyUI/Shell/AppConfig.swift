import CanopyCore
import Foundation

/// Launch options. `canopy` (the launcher) passes them through `open --args`.
///
///   --port <n>            the server's port (else discovered from --repo)
///   --repo <path>         a repo the server serves; `stack-review-port` there gives the port
///   --appearance <a>      dark (default, as the web app) | light | system
///   --dump                headless: hydrate, hold the event stream, print the world as JSON, exit
///   --dump-wait <s>       how long --dump listens for patches (default 4); --shoot settles this long per shot
///   --shoot <dir>         headless: draw each --shot offscreen into <dir>/<name>.png (see Shoot)
///   --shot <name>=<route> [keys…]   one shot; repeatable
///   --size <w>x<h>        the --shoot window (default 1280x800)
///   /v2/... | canopy://…  the first route
public struct AppConfig: Sendable {
    public var port: Int?
    public var repo: String?
    public var route: Route = .forests
    /// the launch address's query (`/v2/tutor?concept=x`), handed to the page that opens
    public var query: [String: String] = [:]
    public var appearance = "dark"
    public var dump = false
    public var dumpWait: Double = 4
    public var shootDir = ""
    public var shots: [String] = []
    public var shootWidth: Double = 1280
    public var shootHeight: Double = 800

    public init() {}

    public static func parse(_ args: [String]) -> AppConfig {
        var c = AppConfig()
        var i = 0
        func next() -> String? { i += 1; return i < args.count ? args[i] : nil }
        while i < args.count {
            let a = args[i]
            switch a {
            case "--port": c.port = next().flatMap(Int.init)
            case "--repo": c.repo = next()
            case "--appearance": c.appearance = next() ?? c.appearance
            case "--dump": c.dump = true
            case "--dump-wait": c.dumpWait = next().flatMap(Double.init) ?? c.dumpWait
            case "--shoot": c.shootDir = next() ?? ""
            case "--shot": if let s = next() { c.shots.append(s) }
            case "--size":
                let wh = (next() ?? "").split(separator: "x").compactMap { Double($0) }
                if wh.count == 2 { c.shootWidth = wh[0]; c.shootHeight = wh[1] }
            default:
                if a.hasPrefix("/v2") || a.hasPrefix("canopy:") { c.route = Route(a); c.query = Route.query(a) }
                // AppKit's own launch args (-NSDocumentRevisionsDebugMode YES, -psn_…) pass through
            }
            i += 1
        }
        return c
    }

    /// The port: --port, else `stack-review-port` run in --repo (or ~/coding/loops).
    public func resolvedPort() -> Int? {
        if let port { return port }
        let repo = NSString(string: repo ?? "~/coding/loops").expandingTildeInPath
        let p = Process()
        p.executableURL = URL(fileURLWithPath: NSString(string: "~/.dotfiles/scripts/stack-review-port").expandingTildeInPath)
        p.currentDirectoryURL = URL(fileURLWithPath: repo)
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        let s = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return Int(s.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// One log line to stderr and ~/.cache/canopy-native/canopy.log — how the app says what it's doing
/// without anyone looking at the window.
public enum Log {
    public static let path = NSString(string: "~/.cache/canopy-native/canopy.log").expandingTildeInPath
    nonisolated(unsafe) public static var quiet = false
    private static let lock = NSLock()

    public static func line(_ s: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let msg = "\(stamp) \(s)\n"
        lock.withLock {
            if !quiet { FileHandle.standardError.write(Data(msg.utf8)) }
            let dir = (path as NSString).deletingLastPathComponent
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            if let h = FileHandle(forWritingAtPath: path) {
                h.seekToEndOfFile()
                h.write(Data(msg.utf8))
                try? h.close()
            } else {
                FileManager.default.createFile(atPath: path, contents: Data(msg.utf8))
            }
        }
    }
}
