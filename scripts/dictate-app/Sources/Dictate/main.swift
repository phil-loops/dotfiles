import AppKit
import CoreGraphics
import ServiceManagement

/// Dictate: the 🎤 key (or 🌐 twice, or `Ctrl-a v` in tmux as `dictate://pane/<id>`) records in the background; 🎤 again or
/// one 🌐 tap delivers the words to whatever had focus at the start. A Claude pane in tmux gets them through `claude-say`,
/// so switching windows mid-sentence costs nothing; any other app is brought back and gets them pasted.
@MainActor
final class Dictate: NSObject, NSApplicationDelegate {
    private let voice = Voice()
    private var taps = GlobeTaps()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var swallows = false
    private var waiting: Timer?
    private var modifierLog = 20
    private let launchedBuild = installedBuild()

    func applicationDidFinishLaunching(_ notification: Notification) {
        voice.idleMenu = { [weak self] menu in self?.idleMenu(menu) }
        voice.reset()
        if UserDefaults.standard.object(forKey: "login.offered") == nil {
            try? SMAppService.mainApp.register()
            UserDefaults.standard.set(true, forKey: "login.offered")
        }
        listen()
        recoverCutOffRecordings()
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.moveToNewBuild() }
        }
    }

    /// Relaunches onto a newer build once one is installed and nothing is being recorded or transcribed, so a rebuild
    /// never cuts off what's being said.
    private func moveToNewBuild() {
        guard let build = installedBuild(), build != launchedBuild, !voice.active, !voice.busy else { return }
        note("moving to build \(build.prefix(8))")
        let reopen = Process()
        reopen.executableURL = URL(fileURLWithPath: "/bin/sh")
        reopen.arguments = ["-c", "sleep 1; open -g \"$0\"", Bundle.main.bundlePath]
        try? reopen.run()
        NSApp.terminate(nil)
    }

    /// Recordings a Dictate before this one was holding when it stopped: each is transcribed, kept beside the log, and the
    /// last put on the clipboard.
    private func recoverCutOffRecordings() {
        let temp = FileManager.default.temporaryDirectory
        let files = ((try? FileManager.default.contentsOfDirectory(at: temp, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("dictate-") && $0.pathExtension == "wav" }
            .sorted { ($0.modificationDate ?? .distantPast) < ($1.modificationDate ?? .distantPast) }
        guard !files.isEmpty else { return }
        Task {
            let kept = URL(fileURLWithPath: ("~/.cache/dictate/recovered" as NSString).expandingTildeInPath)
            try? FileManager.default.createDirectory(at: kept, withIntermediateDirectories: true)
            var last: String?
            for file in files {
                if let text = await voice.recover(file), !text.isEmpty {
                    let saved = kept.appendingPathComponent(file.deletingPathExtension().lastPathComponent + ".txt")
                    try? text.write(to: saved, atomically: true, encoding: .utf8)
                    note("recovered a cut-off recording into \(saved.path)")
                    last = text
                }
                try? FileManager.default.removeItem(at: file)
            }
            guard let last else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(last, forType: .string)
            voice.flash("Recovered a dictation that was cut off; it's on the clipboard")
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            note("link \(url.absoluteString)")
            if let pane = Logic.pane(of: url) { toggle(pane: pane) }
        }
    }

    private func idleMenu(_ menu: NSMenu) {
        func item(_ title: String, _ action: Selector?, on: Bool = false, tag: String? = nil, to parent: NSMenu? = nil) {
            let entry = (parent ?? menu).addItem(withTitle: title, action: action, keyEquivalent: "")
            entry.target = self
            entry.state = on ? .on : .off
            entry.representedObject = tag
        }
        if tap == nil {
            item("Allow 🎤 in Input Monitoring…", #selector(openInputMonitoring))
        } else if !swallows {
            item("Allow in Accessibility so 🎤 stops macOS dictation…", #selector(openAccessibility))
        } else {
            item("🎤 dictates to whatever has focus", nil)
        }
        menu.addItem(.separator())
        item("Leave as a draft", #selector(chooseSend), on: !Settings.send, tag: "draft")
        item("Send it (press Enter)", #selector(chooseSend), on: Settings.send, tag: "send")
        menu.addItem(.separator())
        for (title, current, action) in [("Start sound", Settings.startSound, #selector(chooseStartSound)),
                                         ("Finish sound", Settings.finishSound, #selector(chooseFinishSound))] {
            let sub = NSMenu()
            item("None", action, on: current.isEmpty, tag: "", to: sub)
            sub.addItem(.separator())
            for name in Settings.sounds { item(name, action, on: current == name, tag: name, to: sub) }
            menu.addItem(withTitle: title, action: nil, keyEquivalent: "").submenu = sub
        }
        menu.addItem(.separator())
        item("Live preview", #selector(togglePreview), on: Settings.preview)
        let places = NSMenu()
        for (place, title) in [(Settings.Place.bottom, "Bottom of the screen"), (.top, "Top of the screen"), (.dragged, "Where I last dragged it")] {
            item(title, #selector(choosePlace), on: Settings.place == place, tag: place.rawValue, to: places)
        }
        menu.addItem(withTitle: "Preview position", action: nil, keyEquivalent: "").submenu = places
        menu.addItem(.separator())
        item("Open at login", #selector(toggleLogin), on: SMAppService.mainApp.status == .enabled)
        menu.addItem(withTitle: "Quit Dictate", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
    }

    @objc private func chooseSend(_ sender: NSMenuItem) { Settings.send = sender.representedObject as? String == "send"; voice.reset() }
    @objc private func chooseStartSound(_ sender: NSMenuItem) { Settings.startSound = sender.representedObject as? String ?? ""; Voice.chime(Settings.startSound); voice.reset() }
    @objc private func chooseFinishSound(_ sender: NSMenuItem) { Settings.finishSound = sender.representedObject as? String ?? ""; Voice.chime(Settings.finishSound); voice.reset() }
    @objc private func togglePreview() { Settings.preview.toggle(); voice.reset() }
    @objc private func choosePlace(_ sender: NSMenuItem) {
        Settings.place = (sender.representedObject as? String).flatMap(Settings.Place.init(rawValue:)) ?? .bottom
        voice.reset()
        voice.flash("The preview shows here")
    }
    @objc private func toggleLogin() {
        if SMAppService.mainApp.status == .enabled { try? SMAppService.mainApp.unregister() } else { try? SMAppService.mainApp.register() }
        voice.reset()
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
            case .double: toggleFromKeys()
            case .single where voice.active:
                taps.interrupt()
                note("🌐 finish")
                voice.finish()
            case .single: if modifierLog > 0 { note("🌐 tap") }
            case .none: if modifierLog > 0 { note("🌐 held too long") }
            }
        case .keyDown where code == micKey:
            note("🎤 key")
            if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 { toggleFromKeys() }
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

    /// 🎤 or 🌐 🌐: finishes a recording, or starts one for whatever has focus — the Claude session of the tmux pane in front
    /// when a terminal has focus and that pane holds one, else the focused app itself.
    private func toggleFromKeys() {
        note("toggle")
        if voice.active { voice.finish(); return }
        guard !voice.busy, let front = NSWorkspace.shared.frontmostApplication else { return }
        guard Logic.terminals.contains(front.bundleIdentifier ?? "") else { startPasting(into: front); return }
        Task.detached {
            let clients = run(["tmux", "list-clients", "-F", "#{client_activity}\t#{pane_id}"])
            let pane = Logic.activePane(clients: String(decoding: clients.out, as: UTF8.self))
            let listing = pane == nil ? nil : run([claudeSay, "--json"])
            let session = pane.flatMap { pane in listing.flatMap { $0.status == 0 ? Logic.session(in: pane, listing: $0.out) : nil } }
            await MainActor.run { [weak self] in
                guard let self else { return }
                if let session { self.startClaude(session) } else { self.startPasting(into: front) }
            }
        }
    }

    private func startPasting(into target: NSRunningApplication) {
        note("start → paste into \(target.bundleIdentifier ?? "?")")
        voice.onError = { [weak self] in self?.voice.flash($0) }
        voice.start(to: target.localizedName ?? "this app") { text in
            paste(text, into: target, enter: Settings.send)
            note("pasted")
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
                self.startClaude(session)
            }
        }
    }

    private func startClaude(_ session: Session) {
        note("start → \(session.session_id.prefix(8)) in \(session.pane)")
        voice.onError = { tell(session.pane, $0) }
        voice.start(to: session.topic.isEmpty ? session.pane : session.topic) { text in
            Task.detached {
                let sent = run([claudeSay, session.session_id] + (Settings.send ? [] : ["--draft"]) + ["--unsigned", text])
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

/// Puts `text` into `target` as if typed: brought to the front, pasted with ⌘V, then Enter when sending. The clipboard
/// holds the text only for the paste; what was on it comes back after, unless something else has used it since.
@MainActor
func paste(_ text: String, into target: NSRunningApplication, enter: Bool) {
    let board = NSPasteboard.general
    let saved = (board.pasteboardItems ?? []).map { item in
        item.types.reduce(into: [NSPasteboard.PasteboardType: Data]()) { kept, type in kept[type] = item.data(forType: type) }
    }
    board.clearContents()
    board.setString(text, forType: .string)
    let ours = board.changeCount
    let wasFront = target.isActive
    target.activate()
    DispatchQueue.main.asyncAfter(deadline: .now() + (wasFront ? 0.05 : 0.3)) {
        press(9, flags: .maskCommand)
        if enter { press(36) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            guard board.changeCount == ours, !saved.isEmpty else { return }
            board.clearContents()
            board.writeObjects(saved.map { kept in
                let item = NSPasteboardItem()
                kept.forEach { item.setData($1, forType: $0) }
                return item
            })
        }
    }
}

/// One key press and release, posted as if typed (key codes are US-layout positions: 9 is V, 36 is Return).
func press(_ code: CGKeyCode, flags: CGEventFlags = []) {
    for down in [true, false] {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
        event?.flags = flags
        event?.post(tap: .cghidEventTap)
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

/// What `dictate` last installed (it writes this after the build is signed), or nil before any build.
func installedBuild() -> String? {
    try? String(contentsOfFile: ("~/.cache/dictate/installed" as NSString).expandingTildeInPath, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

extension URL {
    var modificationDate: Date? { try? resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
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
