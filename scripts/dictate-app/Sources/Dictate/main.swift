import AppKit
import CoreGraphics
import ServiceManagement

/// Dictate: 🌐 twice (or `Ctrl-a v` in tmux, as `dictate://pane/<id>`) records in the background; 🌐 twice again drops the
/// transcript as a draft into the Claude session of the tmux pane you were last in, by `claude-say --draft`, so switching
/// windows mid-sentence costs nothing and a pane whose session changed refuses instead of taking the words.
@MainActor
final class Dictate: NSObject, NSApplicationDelegate {
    private let voice = Voice()
    private var taps = GlobeTaps()
    private var tap: CFMachPort?
    private var waiting: Timer?
    private var modifierLog = 20

    func applicationDidFinishLaunching(_ notification: Notification) {
        voice.idleMenu = { [weak self] menu in self?.idleMenu(menu) }
        voice.reset()
        try? SMAppService.mainApp.register()
        listen()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            note("link \(url.absoluteString)")
            if let pane = Logic.pane(of: url) { toggle(pane: pane) }
        }
    }

    private func idleMenu(_ menu: NSMenu) {
        menu.addItem(withTitle: tap == nil ? "Allow 🌐 🌐 in Input Monitoring…" : "🌐 🌐 dictates to your last tmux pane",
                     action: tap == nil ? #selector(openInputMonitoring) : nil, keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Dictate", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
    }

    @objc private func openInputMonitoring() {
        CGRequestListenEventAccess()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
    }

    /// Watches the keyboard for 🌐 once Input Monitoring allows it, checking back until it does.
    private func listen() {
        guard tap == nil else { return }
        if !CGPreflightListenEventAccess() { CGRequestListenEventAccess() }
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue | 1 << CGEventType.keyDown.rawValue)
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly, eventsOfInterest: mask,
                                callback: { _, type, event, context in
                                    let app = Unmanaged<Dictate>.fromOpaque(context!).takeUnretainedValue()
                                    MainActor.assumeIsolated { app.key(type, event) }
                                    return Unmanaged.passUnretained(event)
                                }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap else {
            if waiting == nil { note("no Input Monitoring yet; 🌐 🌐 is off until it's allowed") }
            waiting = waiting ?? Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.listen() }
            }
            return
        }
        waiting?.invalidate()
        waiting = nil
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        note("listening for 🌐 🌐")
        voice.reset()
    }

    private func key(_ type: CGEventType, _ event: CGEvent) {
        let time = ProcessInfo.processInfo.systemUptime
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        if type == .flagsChanged, modifierLog > 0 {
            modifierLog -= 1
            note("modifier key \(code), fn \(event.flags.contains(.maskSecondaryFn) ? "down" : "up")")
        }
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .flagsChanged where code == 63:
            if event.flags.contains(.maskSecondaryFn) { taps.press(at: time); return }
            if taps.release(at: time) { toggleLastPane() } else if modifierLog > 0 { note(taps.pending ? "🌐 tap" : "🌐 held too long") }
        case .keyDown where code == 179 || code == 63:
            break
        default:
            if taps.pending, modifierLog > 0 { note("\(type == .keyDown ? "key" : "event \(type.rawValue)") \(code) between 🌐 taps") }
            taps.interrupt()
        }
    }

    private func toggleLastPane() {
        note("🌐 🌐")
        if voice.active { voice.finish(); return }
        Task.detached {
            let clients = run(["tmux", "list-clients", "-F", "#{client_activity}\t#{pane_id}"])
            let pane = Logic.activePane(clients: String(decoding: clients.out, as: UTF8.self))
            await MainActor.run { [weak self] in
                guard let pane else { NSSound.beep(); return }
                self?.toggle(pane: pane)
            }
        }
    }

    private func toggle(pane: String) {
        if voice.active { note("finish"); voice.finish(); return }
        guard !voice.busy else { note("busy transcribing; ignored"); return }
        Task.detached {
            let listing = run([claudeSay, "--json"])
            let session = listing.status == 0 ? Logic.session(in: pane, listing: listing.out) : nil
            await MainActor.run { [weak self] in
                guard let self else { return }
                guard let session else { note("no Claude session in \(pane)"); tell(pane, "No Claude session in this pane to dictate to"); return }
                note("start → \(session.session_id.prefix(8)) in \(session.pane)")
                self.voice.onError = { tell(session.pane, $0) }
                tell(session.pane, "Listening; 🌐 🌐 to finish")
                self.voice.start(to: session.topic.isEmpty ? session.pane : session.topic) { text in
                    Task.detached {
                        let sent = run([claudeSay, session.session_id, "--draft", "--unsigned", text])
                        guard sent.status != 0 else { note("delivered"); return }
                        note("not delivered: \(String(decoding: sent.err, as: UTF8.self))")
                        let reason = String(decoding: sent.err, as: UTF8.self).split(separator: "\n").first.map(String.init) ?? "claude-say failed"
                        await MainActor.run {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(text, forType: .string)
                            tell(session.pane, "Not delivered (\(reason)); the text is on the clipboard")
                        }
                    }
                }
            }
        }
    }
}

/// One line per thing Dictate saw or did, in ~/.cache/dictate/events.log, so a key that seemed to do nothing can be traced.
func note(_ line: String) {
    let log = URL(fileURLWithPath: ("~/.cache/dictate/events.log" as NSString).expandingTildeInPath)
    let entry = Data("\(ISO8601DateFormatter().string(from: Date())) \(line)\n".utf8)
    if let handle = try? FileHandle(forWritingTo: log) {
        handle.seekToEndOfFile()
        handle.write(entry)
        try? handle.close()
    } else {
        try? entry.write(to: log)
    }
}

let claudeSay = ("~/.dotfiles/scripts/claude-say" as NSString).expandingTildeInPath

/// A message on the pane's tmux status line; a beep when the pane is gone.
func tell(_ pane: String, _ message: String) {
    Task.detached {
        if run(["tmux", "display-message", "-d", "6000", "-t", pane, "Dictate: " + message]).status != 0 {
            await MainActor.run { NSSound.beep() }
        }
    }
}

/// Runs a tool through `zsh -c`, which reads ~/.zshenv for the PATH a GUI app doesn't get.
func run(_ command: [String]) -> (status: Int32, out: Data, err: Data) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = ["-c", "exec \"$0\" \"$@\""] + command
    let out = Pipe(), err = Pipe()
    process.standardOutput = out
    process.standardError = err
    do { try process.run() } catch { return (-1, Data(), Data(error.localizedDescription.utf8)) }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    let errors = err.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, data, errors)
}

if CommandLine.arguments.contains("--selftest") { exit(selfTest()) }
let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { Dictate() }
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
