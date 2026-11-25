import AppKit

/// A spoken review of a forest or a branch: ⌘⇧R on its canopy page has Dictate record into the review's folder while
/// Show writes down each place canopy goes (each page as it opens, the file and line from the place Show already reads
/// once a second, never an extra read of canopy) and the commit on screen there, on the uptime clock Dictate stamps the audio
/// with. ⌘⇧R again (or 🎤) finishes; Dictate cuts the audio at pauses and `show-review-join` files each stretch under
/// the place it was said and posts the notes to the Inbox.
final class SpokenReview {
    static let root = URL(fileURLWithPath: ("~/.cache/show/reviews" as NSString).expandingTildeInPath)

    let dir: URL
    let title: String
    private let repoPath: String
    private var last: String?
    private let writes = DispatchQueue(label: "show.review.trail")
    private let began = Date()
    private(set) var finishing = false

    /// Where a review can start: a forest's page (`/v2/p/loops/<forest>`) or a branch's (`/v2/b/loops/<branch>`).
    static func scope(of address: String) -> (forest: String?, branch: String?)? {
        let path = address.split(separator: "?").first.map(String.init) ?? address
        let parts = path.split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) }
        guard parts.count >= 4, parts[0] == "v2", parts[2] == "loops" else { return nil }
        let name = parts[3...].joined(separator: "/")
        switch parts[1] {
        case "p": return (name, nil)
        case "b": return (nil, name)
        default: return nil
        }
    }

    /// The address without how the window was scrolled or split: two samples at the same spot are one place.
    static func spot(_ address: String) -> String {
        guard var parts = URLComponents(string: address) else { return address }
        parts.queryItems = parts.queryItems?.filter { !["row", "win", "in"].contains($0.name) }
        if parts.queryItems?.isEmpty == true { parts.queryItems = nil }
        return parts.string ?? address
    }

    static func branch(in address: String) -> String? { scope(of: address)?.branch }

    /// Starts a review of the page at `address`, or says why it can't.
    static func begin(at address: String) -> Result<SpokenReview, ReviewRefusal> {
        guard let scope = scope(of: address) else { return .failure(.notAForestOrBranch) }
        let repoPath = (CanopyHost.repo as NSString).expandingTildeInPath
        let name = scope.forest ?? scope.branch ?? "review"
        let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate, .withTime])
        let dir = root.appendingPathComponent("\(stamp)-\(name)")
        let review = SpokenReview(dir: dir, title: name, repoPath: repoPath)
        let branches = scope.forest.map { members(of: $0, in: repoPath) } ?? [scope.branch!]
        var tips: [String: String] = [:]
        for branch in branches { if let sha = tip(of: branch, in: repoPath) { tips[branch] = sha } }
        let header: [String: Any] = ["title": name, "scope": address.split(separator: "?").first.map(String.init) ?? address,
                                     "repo": "loops", "repoPath": repoPath, "startedAt": ISO8601DateFormatter().string(from: Date()), "tips": tips]
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: header, options: [.prettyPrinted, .sortedKeys]).write(to: dir.appendingPathComponent("review.json"))
        } catch {
            return .failure(.couldNotWrite(error.localizedDescription))
        }
        review.sample(address)
        var link = URLComponents(string: "dictate://review/start")!
        link.queryItems = [URLQueryItem(name: "dir", value: dir.path)]
        NSWorkspace.shared.open(link.url!)
        return .success(review)
    }

    private init(dir: URL, title: String, repoPath: String) {
        self.dir = dir
        self.title = title
        self.repoPath = repoPath
    }

    /// Writes down where canopy is when that changed: the moment first, then the commit the branch is at.
    func sample(_ address: String?) {
        guard !finishing, let address else { return }
        let spot = Self.spot(address)
        guard spot != last else { return }
        last = spot
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let trail = dir.appendingPathComponent("trail.jsonl")
        let repoPath = self.repoPath
        writes.async {
            let branch = Self.branch(in: spot)
            let entry: [String: Any] = ["uptimeNs": now, "address": spot, "branch": branch ?? NSNull(),
                                        "commit": branch.flatMap { Self.tip(of: $0, in: repoPath) } ?? NSNull()]
            guard var line = try? JSONSerialization.data(withJSONObject: entry, options: .sortedKeys) else { return }
            line.append(0x0A)
            if let handle = try? FileHandle(forWritingTo: trail) {
                handle.seekToEndOfFile()
                handle.write(line)
                try? handle.close()
            } else {
                try? line.write(to: trail)
            }
        }
    }

    func finish() {
        guard !finishing else { return }
        finishing = true
        var link = URLComponents(string: "dictate://review/finish")!
        link.queryItems = [URLQueryItem(name: "dir", value: dir.path)]
        NSWorkspace.shared.open(link.url!)
    }

    enum State: Equatable { case recording, transcribing, done, neverStarted }

    /// Read from the folder: Dictate's files say whether it recorded, and the notes file that the join step is through.
    var state: State {
        let has = { FileManager.default.fileExists(atPath: self.dir.appendingPathComponent($0).path) }
        if has("notes.md") { return .done }
        if !has("recording.json") { return Date().timeIntervalSince(began) > 8 ? .neverStarted : .recording }
        return finishing || has("utterances.json") ? .transcribing : .recording
    }

    /// The branches whose `stack-project` names `forest`.
    static func members(of forest: String, in repoPath: String) -> [String] {
        git(["config", "--get-regexp", #"^branch\..*\.stack-project$"#], in: repoPath).split(separator: "\n").compactMap { line in
            let fields = line.split(separator: " ", maxSplits: 1)
            guard fields.count == 2, fields[1] == forest else { return nil }
            let key = fields[0].dropFirst("branch.".count)
            return String(key.dropLast(".stack-project".count))
        }
    }

    static func tip(of branch: String, in repoPath: String) -> String? {
        let sha = git(["rev-parse", "--verify", "-q", "refs/heads/\(branch)"], in: repoPath).trimmingCharacters(in: .whitespacesAndNewlines)
        return sha.isEmpty ? nil : sha
    }

    private static func git(_ args: [String], in repoPath: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repoPath] + args
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}

enum ReviewRefusal: Error {
    case notAForestOrBranch
    case couldNotWrite(String)

    var message: String {
        switch self {
        case .notAForestOrBranch: return "⌘⇧R starts a spoken review from a forest's or a branch's page"
        case .couldNotWrite(let why): return "Couldn't make the review's folder: \(why)"
        }
    }
}

extension AppDelegate {
    /// ⌘⇧R: starts a spoken review of the canopy page in front, or finishes the one recording.
    func toggleSpokenReview() {
        guard let controller = workspaces[active] else { return }
        if let review = spokenReview {
            if review.finishing {
                endSpokenReview()
                controller.say("Stopped waiting for that review; its folder is \(review.dir.path)")
            } else {
                review.finish()
                updateTitle()
            }
            return
        }
        guard let place = workspaces[.canopy]?.canopy?.place else {
            controller.say(ReviewRefusal.notAForestOrBranch.message)
            return
        }
        switch SpokenReview.begin(at: place) {
        case .failure(let refusal):
            controller.say(refusal.message)
        case .success(let review):
            spokenReview = review
            updateTitle()
        }
    }

    /// What the title bar says while a review runs.
    var spokenReviewStatus: String? {
        guard let review = spokenReview else { return nil }
        return review.finishing ? "transcribing the review of \(review.title)…" : "● reviewing \(review.title) · ⌘⇧R finishes"
    }

    /// Called each second: a review Dictate finished (by ⌘⇧R or 🎤) stops sampling, and one whose notes are written ends.
    func settleSpokenReview() {
        guard let review = spokenReview else { return }
        switch review.state {
        case .recording:
            return
        case .transcribing:
            if !review.finishing {
                review.finish()
                updateTitle()
            }
        case .done:
            endSpokenReview()
            workspaces[active]?.say("Your review of \(review.title) is in the Inbox (⌘4) and on the clipboard")
        case .neverStarted:
            endSpokenReview()
            workspaces[active]?.say("Dictate didn't start recording; is it running and free?")
        }
    }

    private func endSpokenReview() {
        spokenReview = nil
        updateTitle()
    }
}
