import CanopyCore
import CryptoKit
import Foundation
import Observation

enum BenchSubject: Hashable, Sendable {
    case branch(repo: String, name: String)
    case forest(repo: String, project: String)

    @MainActor static func current(_ app: AppModel) -> BenchSubject? {
        switch app.router.route {
        case .review(let repo, let name, _):
            return app.store.view(Branch.self, "\(repo):\(name)") == nil ? nil : .branch(repo: repo, name: name)
        case .forest(let repo, let project): return .forest(repo: repo, project: project)
        default: return nil
        }
    }
}

struct BenchDocument: Equatable, Sendable {
    struct Head: Decodable {
        struct Scenario: Decodable {
            struct Group: Decodable { let id: String?; let branch: String? }
            let repo: String
            let project: String?
            let groups: [Group]?
        }
        let mode: String?
        let title: String?
        let bench: Scenario?
    }

    let url: URL
    let title: String
    let repo: String
    let project: String?
    let branches: Set<String>
    let ambiguousBranches: Set<String>
    let revision: String

    init?(_ url: URL, _ data: Data) {
        guard let head = try? JSONDecoder().decode(Head.self, from: data), head.mode == "bench",
              let bench = head.bench, !bench.repo.isEmpty else { return nil }
        self.url = url.standardizedFileURL.resolvingSymlinksInPath()
        title = head.title?.isEmpty == false ? head.title! : url.deletingPathExtension().lastPathComponent
        repo = bench.repo
        project = bench.project
        branches = Set((bench.groups ?? []).compactMap(\.branch))
        ambiguousBranches = Set((bench.groups ?? []).filter { $0.branch == nil }.map { $0.id ?? "undefined" }).intersection(branches)
        revision = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func matches(_ subject: BenchSubject) -> Bool {
        switch subject {
        case .branch(let repo, let name): return self.repo == repo && branches.contains(name)
        case .forest(let repo, let project): return self.repo == repo && self.project == project
        }
    }
}

struct BenchObservation: Equatable, Sendable {
    let group: String
    let fixed: Int
    let total: Int
    let environment: String
    let recordedAt: String

    static func parse(_ line: String) -> BenchObservation? {
        guard line.utf8.count <= 8192,
              let expression = try? NSRegularExpression(pattern: #"^(.+): ([0-9]+) of ([0-9]+) fixed on (.+), (\S+)$"#),
              let match = expression.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { return nil }
        func field(_ index: Int) -> String? { Range(match.range(at: index), in: line).map { String(line[$0]) } }
        guard let group = field(1), let fixed = field(2).flatMap(Int.init), let total = field(3).flatMap(Int.init),
              fixed <= total, let environment = field(4), let recordedAt = field(5), parseISO(recordedAt) != nil else { return nil }
        return BenchObservation(group: group, fixed: fixed, total: total, environment: environment, recordedAt: recordedAt)
    }

    var text: String { "\(fixed) of \(total) fixed on \(environment) · \(recordedAt)" }
}

enum BenchStatus: Equatable, Sendable {
    case noRuns
    case observations([BenchObservation])
    case unavailable

    static func decode(_ output: String) -> BenchStatus {
        let lines = output.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
        if lines == ["no runs yet"] { return .noRuns }
        let observations = lines.compactMap(BenchObservation.parse)
        guard observations.count == lines.count else { return .unavailable }
        return .observations(observations)
    }
}

struct BenchEntry: Equatable, Sendable {
    let document: BenchDocument
    let status: BenchStatus

    func observations(for subject: BenchSubject) -> [BenchObservation] {
        guard case .observations(let rows) = status else { return [] }
        if case .branch(_, let name) = subject { return rows.filter { $0.group == name } }
        return rows
    }

    func totals(for subject: BenchSubject) -> [BenchObservation]? {
        var totals: [BenchObservation] = []
        for row in observations(for: subject) {
            guard let index = totals.firstIndex(where: { $0.environment == row.environment && $0.recordedAt == row.recordedAt }) else {
                totals.append(row)
                continue
            }
            let prior = totals[index]
            let fixed = prior.fixed.addingReportingOverflow(row.fixed), total = prior.total.addingReportingOverflow(row.total)
            guard !fixed.overflow, !total.overflow else { return nil }
            totals[index] = BenchObservation(group: "", fixed: fixed.partialValue, total: total.partialValue,
                                             environment: row.environment, recordedAt: row.recordedAt)
        }
        return totals
    }
}

struct BenchIO: Sendable {
    var directory: URL
    var read: @Sendable (URL) throws -> Data = { try LocalDocumentFile.read($0).data }
    var list: @Sendable (URL) throws -> [URL] = {
        guard FileManager.default.fileExists(atPath: $0.path) else { return [] }
        var failure: Error?
        guard let walk = FileManager.default.enumerator(at: $0, includingPropertiesForKeys: [.isRegularFileKey], errorHandler: { _, error in
            failure = error
            return false
        }) else { throw CocoaError(.fileReadUnknown) }
        let files = walk.compactMap { $0 as? URL }
        if let failure { throw failure }
        return try files.filter { try $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true }
    }
    var status: @Sendable (URL, Data) throws -> String = { try BenchIO.recordedStatus($0, data: $1) }

    static var local: BenchIO {
        let path = ProcessInfo.processInfo.environment["SHOW_DIR"] ?? "~/.local/share/show"
        return BenchIO(directory: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
    }

    static func recordedStatus(_ url: URL, data: Data, environment: [String: String] = ProcessInfo.processInfo.environment) throws -> String {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temporary) }
        let frozen = temporary.appendingPathComponent(url.lastPathComponent)
        try data.write(to: frozen)
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: ("~/.dotfiles/scripts/bench" as NSString).expandingTildeInPath)
        process.arguments = ["status", frozen.path]
        var childEnvironment = environment
        childEnvironment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (childEnvironment["PATH"] ?? "")
        process.environment = childEnvironment
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 8, execute: timeout)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeout.cancel()
        guard process.terminationStatus == 0, data.count <= 1_048_576 else { throw CocoaError(.fileReadUnknown) }
        return String(decoding: data, as: UTF8.self)
    }

    private func inventory() throws -> [URL: (document: BenchDocument, data: Data)] {
        var files: [URL: (document: BenchDocument, data: Data)] = [:]
        for url in try list(directory) where url.pathExtension == "json" {
            try Task.checkCancellation()
            guard let data = try? read(url), data.count <= 8_388_608, let document = BenchDocument(url, data) else { continue }
            files[document.url] = (document, data)
        }
        return files
    }

    private func matching(_ documents: [BenchDocument], _ subject: BenchSubject) -> [BenchDocument] {
        let active = directory.standardizedFileURL.resolvingSymlinksInPath()
        return documents.filter { $0.url.deletingLastPathComponent().path == active.path && $0.matches(subject) }
            .sorted { ($0.title, $0.url.path) < ($1.title, $1.url.path) }
    }

    func documents(for subject: BenchSubject) throws -> [BenchDocument] {
        try matching(inventory().values.map(\.document), subject)
    }

    func load(_ subject: BenchSubject) throws -> [BenchEntry] {
        let files = try inventory()
        let names = Dictionary(grouping: files.values.map(\.document), by: { $0.url.deletingPathExtension().lastPathComponent })
        return try matching(files.values.map(\.document), subject).map { document in
            try Task.checkCancellation()
            let ambiguous: Bool
            if case .branch(_, let name) = subject { ambiguous = document.ambiguousBranches.contains(name) } else { ambiguous = false }
            let output = !ambiguous && names[document.url.deletingPathExtension().lastPathComponent]?.count == 1 ? try? status(document.url, files[document.url]!.data) : nil
            try Task.checkCancellation()
            let current = (try? read(document.url)).flatMap { BenchDocument(document.url, $0) }
            let status = current == document ? output.map(BenchStatus.decode) ?? .unavailable : .unavailable
            return BenchEntry(document: document, status: status)
        }
    }

    func validate(_ document: BenchDocument, for subject: BenchSubject) -> Bool {
        guard let data = try? read(document.url), let current = BenchDocument(document.url, data) else { return false }
        return current == document && current.matches(subject)
    }
}

@MainActor
@Observable
final class BenchLibrary {
    private(set) var subject: BenchSubject?
    private(set) var entries: [BenchEntry] = []
    private(set) var loading = false
    private(set) var failed = false
    @ObservationIgnored var io = BenchIO.local
    @ObservationIgnored private var generation = 0

    static func of(_ app: AppModel) -> BenchLibrary { app.state { BenchLibrary() } }

    func load(_ subject: BenchSubject) async {
        guard !Task.isCancelled else { return }
        generation &+= 1
        let mine = generation, io = io
        if self.subject != subject { entries = [] }
        self.subject = subject
        loading = true
        failed = false
        defer { if mine == generation { loading = false } }
        let worker = Task.detached(priority: .utility) { Result { try io.load(subject) } }
        let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
        guard mine == generation, !Task.isCancelled else { return }
        switch result {
        case .success(let entries): self.entries = entries
        case .failure: entries = []; failed = true
        }
    }
}
