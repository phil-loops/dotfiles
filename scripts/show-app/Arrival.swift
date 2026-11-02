import AppKit
import CanopyCore
import UserNotifications

/// `show --focus <file>` appends the file's path here before handing it over; any other `show <file>` arrives quietly.
/// `SHOW_FOCUS_REQUESTS` points a test at a scratch file.
let focusRequestsPath = ProcessInfo.processInfo.environment["SHOW_FOCUS_REQUESTS"]
    ?? ((Bundle.main.bundlePath as NSString).deletingLastPathComponent as NSString).appendingPathComponent("focus-requests")

/// The paths sessions asked to bring forward since the last look, emptying the file. Moved aside first, so a launcher
/// appending right now starts a fresh file instead of losing its line.
func takeFocusRequests() -> Set<String> {
    let taken = focusRequestsPath + ".\(ProcessInfo.processInfo.processIdentifier)"
    guard (try? FileManager.default.moveItem(atPath: focusRequestsPath, toPath: taken)) != nil else { return [] }
    defer { try? FileManager.default.removeItem(atPath: taken) }
    let text = (try? String(contentsOfFile: taken, encoding: .utf8)) ?? ""
    return Set(text.split(separator: "\n").map { canonicalPath(String($0)) })
}

/// What the session that sent a deck is working on, from `claude-say --topic <replyTo>`: its stack-project, else its branch,
/// else its worktree's name. Remembered per `replyTo`, so a deck keeps its topic after the session ends.
enum Topics {
    private static var asked = Set<String>()
    /// Called on the main thread when a lookup the shelf started has an answer.
    static var onChange: (() -> Void)?

    /// The remembered topic; an unknown `replyTo` is looked up once per launch in the background.
    static func cached(_ replyTo: String?) -> String? {
        guard let replyTo, !replyTo.isEmpty else { return nil }
        if let topic = prefs.string(forKey: "topic." + replyTo) { return topic }
        if asked.insert(replyTo).inserted {
            resolve(replyTo) { topic in
                if topic != nil { onChange?() }
            }
        }
        return nil
    }

    /// Looks the topic up now, off the main thread, and remembers it; `done` runs on the main thread.
    static func resolve(_ replyTo: String, done: @escaping (String?) -> Void) {
        asked.insert(replyTo)
        DispatchQueue.global(qos: .userInitiated).async {
            let topic = lookup(replyTo)
            DispatchQueue.main.async {
                if let topic { prefs.set(topic, forKey: "topic." + replyTo) }
                done(topic ?? prefs.string(forKey: "topic." + replyTo))
            }
        }
    }

    private static func lookup(_ replyTo: String) -> String? {
        let process = Zsh.process("exec \"$0\" \"$@\"", [claudeSayPath, "--topic", replyTo])
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let topic = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return process.terminationStatus == 0 && !topic.isEmpty ? topic : nil
    }
}

/// The macOS notification a quiet arrival posts; clicking it opens the deck and brings Show forward.
final class ArrivalNotices: NSObject, UNUserNotificationCenterDelegate {
    static let shared = ArrivalNotices()
    var onOpen: ((String) -> Void)?
    private var started = false

    func post(path: String, title: String, topic: String?, workspace: Workspace) {
        let center = UNUserNotificationCenter.current()
        if !started {
            started = true
            center.delegate = self
        }
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = [title, topic].compactMap { $0 }.joined(separator: " · ")
            content.body = "Waiting in \(workspace.name)"
            content.userInfo = ["path": path]
            center.add(UNNotificationRequest(identifier: path, content: content, trigger: nil))
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let path = response.notification.request.content.userInfo["path"] as? String {
            DispatchQueue.main.async { self.onOpen?(path) }
        }
        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }
}

extension AppDelegate {
    /// Whether `show <path>` may only land on the shelf: `--api` and `--focus` (and a clicked canopy:// link) come forward.
    func arrivesQuietly(_ path: String, focus: Set<String>) -> Bool {
        Workspace.route(path).workspace != .api && !focus.contains(path)
    }

    /// A deck a session sent without `--focus` while Show isn't frontmost: it goes to the top of its shelf group (the rail
    /// badge counts it) and a notification names it and its session's topic. Nothing switches, opens or comes forward.
    /// A canopy page waits instead in `CanopyArrivals`, counted on ⌘6's badge, until ⌘6 or its notification opens it.
    func arrive(_ path: String) {
        if Workspace.route(path).workspace == .canopy {
            return arriveInCanopy(path)
        }
        prefs.set(Date(), forKey: "arrived." + path)
        refreshLibrary(force: true)
        guard snapshotPath == nil, let entry = shelfEntry(path) else { return }
        let replyTo = (try? loadDeck(path))?.replyTo ?? (try? loadTutorSession(path))?.replyTo
        announce(path: path, target: path, title: entry.title, workspace: entry.workspace, replyTo: replyTo)
    }

    private func arriveInCanopy(_ path: String) {
        let request = CanopyRequest(path: path)
        let route = request.route ?? ""
        CanopyArrivals.add(route)
        refreshLibrary(force: true)
        guard snapshotPath == nil else { return }
        announce(path: path, target: "canopy:" + route, title: canopyTitle(route), workspace: .canopy, replyTo: request.replyTo)
    }

    /// Records the arrival in History and posts its notification (not under the selftest), naming the sending session's
    /// topic once it's known.
    private func announce(path: String, target: String, title: String, workspace: Workspace, replyTo: String?) {
        let notify = selfTest == nil
        guard let replyTo, !replyTo.isEmpty else {
            ShowHistory.record(HistoryRecord(kind: .arrived, target: target, workspace: workspace, title: title, topic: nil))
            if notify { ArrivalNotices.shared.post(path: path, title: title, topic: nil, workspace: workspace) }
            return
        }
        Topics.resolve(replyTo) { [weak self] topic in
            self?.refreshLibrary(force: true)
            ShowHistory.record(HistoryRecord(kind: .arrived, target: target, workspace: workspace, title: title, topic: topic))
            if notify { ArrivalNotices.shared.post(path: path, title: title, topic: topic, workspace: workspace) }
        }
    }
}
