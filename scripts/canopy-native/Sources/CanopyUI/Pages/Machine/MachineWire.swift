import CanopyCore
import Foundation

// GET /previews, /footprint, /preview-log (srv/preview.py, workstation.ts). Not store entities:
// read while the page is open.

/// A string the server sends as a number on some paths ("port": 3000 vs "3000").
struct Flex: Decodable, Equatable {
    var value: String
    init(_ v: String) { value = v }
    init(from d: Decoder) throws {
        let c = try d.singleValueContainer()
        if let s = try? c.decode(String.self) { value = s }
        else if let n = try? c.decode(Double.self) { value = n.rounded() == n ? String(Int(n)) : String(n) }
        else { value = "" }
    }
}

struct Server: Decodable, Equatable {
    var name: String
    var port: String
    var dir: String
    var branch: String?
    var url: String?
    var state: String
    var age: String
    var health: String
    var latency: Double?
    var error: String?
    /// a --jobs worker log exists beside the web log
    var jobs: Bool?
    /// false: a next-dev listener no preview session owns (task dev, a leftover headless server)
    var managed: Bool?
    var pid: String?
    /// commits the served checkout trails origin/main
    var behind: String?
    /// the server's own X-Dev-Worktree claim: "<branch>@<sha> <path>"
    var serves: String?
    var servesMismatch: Bool?
    /// the natural "before" for a swap: its stack parent, else main
    var swapTo: String?

    init(name: String, port: String, dir: String, branch: String? = nil, url: String? = nil, state: String = "up", age: String = "",
         health: String = "healthy", latency: Double? = nil, error: String? = nil, jobs: Bool? = nil, managed: Bool? = nil,
         pid: String? = nil, behind: String? = nil, serves: String? = nil, servesMismatch: Bool? = nil, swapTo: String? = nil) {
        self.name = name; self.port = port; self.dir = dir; self.branch = branch; self.url = url; self.state = state; self.age = age
        self.health = health; self.latency = latency; self.error = error; self.jobs = jobs; self.managed = managed; self.pid = pid
        self.behind = behind; self.serves = serves; self.servesMismatch = servesMismatch; self.swapTo = swapTo
    }

    enum K: String, CodingKey { case name, port, dir, branch, url, state, age, health, latency, error, jobs, managed, pid, behind, serves, servesMismatch, swapTo }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        port = (try? c.decode(Flex.self, forKey: .port))?.value ?? ""
        dir = (try? c.decode(String.self, forKey: .dir)) ?? ""
        branch = try? c.decode(String.self, forKey: .branch)
        url = try? c.decode(String.self, forKey: .url)
        state = (try? c.decode(String.self, forKey: .state)) ?? ""
        age = (try? c.decode(Flex.self, forKey: .age))?.value ?? ""
        health = (try? c.decode(String.self, forKey: .health)) ?? ""
        latency = try? c.decode(Double.self, forKey: .latency)
        error = try? c.decode(String.self, forKey: .error)
        jobs = try? c.decode(Bool.self, forKey: .jobs)
        managed = try? c.decode(Bool.self, forKey: .managed)
        pid = (try? c.decode(Flex.self, forKey: .pid))?.value
        behind = (try? c.decode(Flex.self, forKey: .behind))?.value
        serves = try? c.decode(String.self, forKey: .serves)
        servesMismatch = try? c.decode(Bool.self, forKey: .servesMismatch)
        swapTo = try? c.decode(String.self, forKey: .swapTo)
    }

    /// A server's id on the page: its port names it exactly (one dir can host a preview and a stray).
    var sid: String { port.isEmpty ? dir : port }
    var owned: Bool { managed != false }
    var label: String { (branch?.isEmpty == false ? branch : nil) ?? name }
}

struct Service: Decodable, Equatable {
    var name: String
    var status: String
    var up: Bool
    var state: String?
}

struct SchemaDrift: Decodable, Equatable {
    struct PG: Decodable, Equatable { var head: String; var behind: Int; var ahead: Int; var latestBehind: String; var latestAhead: String }
    struct CH: Decodable, Equatable { var head: String; var behind: Int; var latestBehind: String }
    var pg: PG?
    var ch: CH?

    enum K: String, CodingKey { case pg, ch }
    init(pg: PG? = nil, ch: CH? = nil) { self.pg = pg; self.ch = ch }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        pg = try? c.decode(PG.self, forKey: .pg)
        ch = try? c.decode(CH.self, forKey: .ch)
    }
}

struct Check: Decodable, Equatable {
    var name: String
    var detail: String
}

struct Doctor: Decodable, Equatable {
    var checks: [Check]
    var ok: Bool
    var broken: [Check]
}

struct Substrate: Decodable, Equatable {
    var project: String
    var dir: String?
    var home: Bool?
    var shared: Bool
    var starting: Bool?
    var err: String?
    var db: String?
    var up: Int
    var total: Int
    var services: [Service]
    var schema: SchemaDrift?
    var doctor: Doctor?

    init(project: String, dir: String? = nil, home: Bool? = nil, shared: Bool = true, starting: Bool? = nil, err: String? = nil,
         db: String? = nil, up: Int = 0, total: Int = 0, services: [Service] = [], schema: SchemaDrift? = nil, doctor: Doctor? = nil) {
        self.project = project; self.dir = dir; self.home = home; self.shared = shared; self.starting = starting; self.err = err
        self.db = db; self.up = up; self.total = total; self.services = services; self.schema = schema; self.doctor = doctor
    }

    /// the stack has services and not all of them are up
    var down: Bool { total == 0 || up < total }
}

struct Previews: Decodable {
    var previews: [Server]?
    var substrate: Substrate
}

struct Footprint: Decodable, Equatable {
    struct Proc: Decodable, Equatable { var rssMb: Double; var pid: Int; var cpu: Double; var name: String }
    struct Swap: Decodable, Equatable { var totalMb: Double; var usedMb: Double }
    struct Machine: Decodable, Equatable {
        var totalMb: Double
        /// "ok" | "high" | "critical"
        var pressure: String
        var levelPct: Double
        var freeMb: Double
        var activeMb: Double
        var inactiveMb: Double
        var wiredMb: Double
        var compressedMb: Double
        var swap: Swap
        var top: [Proc]
    }
    struct Disk: Decodable, Equatable { var usedGb: Double?; var totalGb: Double?; var pct: Double? }
    struct Hygiene: Decodable, Equatable { var at: Double; var days: Double; var stripped: Int; var apparentMb: Double; var kept: Int }
    struct Repo: Decodable, Equatable { var worktrees: Int; var scratch: Int; var nodeModulesClones: Int; var disk: Disk; var hygiene: Hygiene? }
    struct ServerProc: Decodable, Equatable { var pid: Int; var rssMb: Double; var threads: Int; var children: Int; var uptimeS: Double; var caches: [String: Int] }
    var machine: Machine
    var repo: Repo
    var server: ServerProc
}

struct PreviewLog: Decodable { var log: String? }

enum MachineText {
    private static func shortMig(_ m: String) -> String {
        var s = m
        if let r = s.range(of: "^[0-9]+_?", options: .regularExpression) { s.removeSubrange(r) }
        if s.hasSuffix(".sql") { s.removeLast(4) }
        return s
    }

    /// The shared DB's drift from main in words, or "" when it's in step.
    static func drift(_ sc: SchemaDrift?) -> String {
        var bits: [String] = []
        if let pg = sc?.pg, pg.behind > 0 { bits.append("missing \(pg.behind) migration\(pg.behind == 1 ? "" : "s") (\(shortMig(pg.latestBehind)))") }
        if let pg = sc?.pg, pg.ahead > 0 { bits.append("\(pg.ahead) not in main (\(shortMig(pg.latestAhead)))") }
        if let ch = sc?.ch, ch.behind > 0 { bits.append("clickhouse \(ch.behind) behind") }
        return bits.joined(separator: " · ")
    }

    static func shortDir(_ d: String) -> String { d.split(separator: "/").last.map(String.init) ?? d }
    static func gb(_ mb: Double) -> String { String(format: "%.1f", mb / 1024) }
    static func ago(_ s: Double) -> String {
        let s = Int(s)
        return s < 3600 ? "\(s / 60)m" : "\(s / 3600)h \((s % 3600) / 60)m"
    }

    /// A docker service's short name: drop the compose project prefix (or "loops-") and the "-1" replica suffix.
    static func service(_ n: String, project: String) -> String {
        var s = !project.isEmpty && n.hasPrefix(project + "-") ? String(n.dropFirst(project.count + 1)) : (n.hasPrefix("loops-") ? String(n.dropFirst(6)) : n)
        if s.hasSuffix("-1") { s.removeLast(2) }
        return s
    }
}
