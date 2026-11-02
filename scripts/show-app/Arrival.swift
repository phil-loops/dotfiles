import AppKit
import CanopyCore
import UserNotifications

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

/// The macOS notification an arrival posts; clicking it opens the target and brings Show forward.
final class ArrivalNotices: NSObject, UNUserNotificationCenterDelegate {
    static let shared = ArrivalNotices()
    var onOpen: ((Target) -> Void)?
    private var started = false

    func post(_ target: Target, title: String, topic: String?, workspace: Workspace) {
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
            content.userInfo = ["target": target.key]
            center.add(UNNotificationRequest(identifier: target.key, content: content, trigger: nil))
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let key = response.notification.request.content.userInfo["target"] as? String {
            DispatchQueue.main.async { self.onOpen?(Target(key: key)) }
        }
        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }
}

extension AppDelegate {
    /// Takes one request from any door: what `comesForward` lets through opens and brings Show forward; the rest arrives.
    func handle(_ request: ShowRequest) {
        if comesForward(request) {
            open(request.target)
            if snapshotPath == nil && selfTest == nil {
                NSApp.activate(ignoringOtherApps: true)
            }
        } else {
            arrive(request)
        }
    }

    /// Something a session sent without being asked to show it: an `arrived` event (it waits in History, a canopy page on ⌘6's
    /// badge, a deck at the top of its shelf) and a notification naming it and the session's topic. Nothing switches or opens.
    func arrive(_ request: ShowRequest) {
        let target = request.target
        let workspace = target.workspace
        let title: String
        var session = request.session
        switch target {
        case .document(let path):
            title = shelfEntry(path)?.title ?? (path as NSString).lastPathComponent
            session = session ?? (try? loadDeck(path))?.replyTo ?? (try? loadTutorSession(path))?.replyTo
        case .canopy(let route):
            title = canopyTitle(route)
        case .api:
            title = "API console"
        }
        session = session.flatMap { $0.isEmpty ? nil : $0 }
        showEvents.append(ShowEvent(kind: .arrived, target: target, workspace: workspace, title: title, session: session))
        refreshLibrary(force: true)
        guard snapshotPath == nil, selfTest == nil else { return }
        guard let session else {
            ArrivalNotices.shared.post(target, title: title, topic: nil, workspace: workspace)
            return
        }
        Topics.resolve(session) { [weak self] topic in
            self?.refreshLibrary(force: true)
            ArrivalNotices.shared.post(target, title: title, topic: topic, workspace: workspace)
        }
    }
}
