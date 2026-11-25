import AppKit
import CoreGraphics
import ServiceManagement

/// Dictate: the 🎤 key (or 🌐 twice, or `Ctrl-a v` in tmux as `dictate://pane/<id>`) records in the background; 🎤 again or
/// one 🌐 tap drops the transcript as a draft into the Claude session of the tmux pane you were last in, by `claude-say
/// --draft`, so switching windows mid-sentence costs nothing and a pane whose session changed refuses the words.
@MainActor
final class Dictate: NSObject, NSApplicationDelegate {
    private let voice = Voice()
    private var taps = GlobeTaps()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var swallows = false
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
        menu.addItem(withTitle: tap == nil ? "Allow 🎤 in Input Monitoring…" : "🎤 dictates to your last tmux pane",
                     action: tap == nil ? #selector(openInputMonitoring) : nil, keyEquivalent: "").target = self
        if tap != nil, !swallows {
            menu.addItem(withTitle: "Allow in Accessibility so 🎤 stops macOS dictation…", action: #selector(openAccessibility), keyEquivalent: "").target = self
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Dictate", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
    }

    @objc private func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func openInputMonitoring() {
        CGRequestListenEventAccess()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
    }

    /// Watches the keyboard once Input Monitoring allows it. With Accessibility too, the watch also swallows the 🎤 key so
    /// macOS's own dictation never starts beside Dictate; it checks back every few seconds and upgrades when that's granted.
    private func listen() {
        let trusted = AXIsProcessTrusted()
        guard tap == nil || (trusted && !swallows) else { return }
        if !CGPreflightListenEventAccess() { CGRequestListenEventAccess() }
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue | 1 << CGEventType.keyDown.rawValue
                               | 1 << CGEventType.keyUp.rawValue | 1 << systemDefined)
        let created = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: trusted ? .defaultTap : .listenOnly,
                                        eventsOfInterest: mask, callback: { _, type, event, context in
                                            let app = Unmanaged<Dictate>.fromOpaque(context!).takeUnretainedValue()
                                            let swallow = MainActor.assumeIsolated { app.key(type, event) }
                                            return swallow ? nil : Unmanaged.passUnretained(event)
                                        }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        waiting = waiting ?? Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.listen() }
        }
        guard let created else {
            if tap == nil { note("no Input Monitoring yet; the keys are off until it's allowed") }
            return
        }
        if let tap, let source {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            CFMachPortInvalidate(tap)
        }
        tap = created
        swallows = trusted
        source = CFMachPortCreateRunLoopSource(nil, created, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: created, enable: true)
        if trusted { waiting?.invalidate(); waiting = nil }
        note(trusted ? "listening; 🎤 is Dictate's alone" : "listening; macOS dictation also hears 🎤 until Accessibility is allowed")
        voice.reset()
    }

    /// Acts on one key event; true when the event should go no further (the 🎤 key, once Dictate may swallow it).
    private func key(_ type: CGEventType, _ event: CGEvent) -> Bool {
        let time = ProcessInfo.processInfo.systemUptime
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        if type == .flagsChanged, modifierLog > 0 {
            modifierLog -= 1
            note("modifier key \(code), fn \(event.flags.contains(.maskSecondaryFn) ? "down" : "up")")
        }
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .keyUp where code == micKey:
            return swallows
        case .keyUp:
            break
        case .flagsChanged where code == 63:
            if event.flags.contains(.maskSecondaryFn) { taps.press(at: time); return false }
            switch taps.release(at: time) {
            case .double: toggleLastPane()
            case .single where voice.active:
                taps.interrupt()
                note("🌐 finish")
                voice.finish()
            case .single: if modifierLog > 0 { note("🌐 tap") }
            case .none: if modifierLog > 0 { note("🌐 held too long") }
            }
        case .keyDown where code == micKey:
            note("🎤 key")
            if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 { toggleLastPane() }
            return swallows
        case .keyDown where code == 179 || code == 63:
            break
        case let other where other.rawValue == systemDefined:
            if let key = NSEvent(cgEvent: event), key.subtype.rawValue == 8 {
                note("special key \((key.data1 & 0xFFFF0000) >> 16), \((key.data1 & 0xFF00) >> 8 == 0xA ? "down" : "up")")
            }
        default:
            if type == .keyDown, code >= 160 { note("special key \(code)") }
            if taps.pending, modifierLog > 0 { note("\(type == .keyDown ? "key" : "event \(type.rawValue)") \(code) between 🌐 taps") }
            taps.interrupt()
        }
        return false
    }

    private func toggleLastPane() {
        note("toggle")
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

/// The 🎤 dictation key on the function row (F5 on recent Mac keyboards), as a key code.
let micKey: Int64 = 176
/// NX_SYSDEFINED: media and special keys that don't arrive as plain key presses.
let systemDefined: UInt32 = 14

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
