import AppKit

var arguments = Array(CommandLine.arguments.dropFirst())
if let flag = arguments.firstIndex(of: "--tutor-ask") {
    guard flag + 2 < arguments.count else {
        FileHandle.standardError.write("usage: Show --tutor-ask <session.json> <message>\n".data(using: .utf8)!)
        exit(64)
    }
    exit(tutorAsk(arguments[flag + 1], arguments[flag + 2]))
}
if let flag = arguments.firstIndex(of: "--tutor-check") {
    guard flag + 1 < arguments.count else {
        FileHandle.standardError.write("usage: Show --tutor-check <session.json>\n".data(using: .utf8)!)
        exit(64)
    }
    exit(tutorCheck(arguments[flag + 1]))
}
if let flag = arguments.firstIndex(of: "--check-routing") {
    guard flag + 1 < arguments.count else {
        FileHandle.standardError.write("usage: Show --check-routing <file.json>\n".data(using: .utf8)!)
        exit(64)
    }
    exit(checkRouting(arguments[flag + 1]))
}
var snapshotPath: String?
if let flag = arguments.firstIndex(of: "--snapshot"), flag + 1 < arguments.count {
    snapshotPath = arguments[flag + 1]
    arguments.removeSubrange(flag...(flag + 1))
}
let deckPaths = arguments.filter { !$0.hasPrefix("-") }.map { ($0 as NSString).expandingTildeInPath }

let app = NSApplication.shared
let delegate: NSApplicationDelegate
if let snapshotPath {
    guard !deckPaths.isEmpty else {
        FileHandle.standardError.write("usage: Show <file.json>… --snapshot out.png\n".data(using: .utf8)!)
        exit(64)
    }
    let suite = "com.philbrockman.show.snapshot"
    UserDefaults.standard.removePersistentDomain(forName: suite)
    prefs = UserDefaults(suiteName: suite) ?? .standard
    app.setActivationPolicy(.prohibited)
    delegate = AppDelegate(launchPaths: deckPaths, snapshotPath: snapshotPath)
} else {
    app.setActivationPolicy(.regular)
    delegate = AppDelegate(launchPaths: deckPaths)
}
app.delegate = delegate
app.run()
