import AppKit
import Carbon
import CoreGraphics
import ServiceManagement

/// Dictate: the 🎤 key (or 🌐 twice, or `Ctrl-a v` in tmux as `dictate://pane/<id>`) records in the background; 🎤 again or
/// one 🌐 tap delivers the words to whatever had focus at the start. A Claude pane in tmux gets them through `claude-say`,
/// so switching windows mid-sentence costs nothing; any other app is brought back and gets them pasted.
@MainActor
final class Dictate: NSObject, NSApplicationDelegate, NSMenuDelegate {
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

    @objc private func copyLast() {
        guard let text = lastDictation() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private var auditioning: NSSound?

    /// A sound plays as the pointer reaches it in the start or finish menu, so you hear each one before choosing.
    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        auditioning?.stop()
        auditioning = (item?.representedObject as? String).flatMap { $0.isEmpty ? nil : NSSound(named: $0) }
        auditioning?.play()
    }

    private func idleMenu(_ menu: NSMenu) {
        @discardableResult
        func item(_ title: String, _ symbol: String?, _ action: Selector?, on: Bool = false, tag: String? = nil, to parent: NSMenu? = nil) -> NSMenuItem {
            let entry = (parent ?? menu).addItem(withTitle: title, action: action, keyEquivalent: "")
            entry.target = self
            entry.state = on ? .on : .off
            entry.representedObject = tag
            entry.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
            return entry
        }
        if tap == nil {
            item("Allow the Mic Key in Input Monitoring…", "exclamationmark.triangle", #selector(openInputMonitoring))
            menu.addItem(.separator())
        } else if !swallows {
            item("Allow in Accessibility to Silence macOS Dictation…", "exclamationmark.triangle", #selector(openAccessibility))
            menu.addItem(.separator())
        }
        if lastDictation() != nil {
            item("Copy Last Dictation", "doc.on.doc", #selector(copyLast))
            menu.addItem(.separator())
        }
        for (title, symbol, current, action) in [("Start Sound", "play.circle", Settings.startSound, #selector(chooseStartSound)),
                                                 ("Finish Sound", "stop.circle", Settings.finishSound, #selector(chooseFinishSound))] {
            let sub = NSMenu()
            sub.delegate = self
            item("None", nil, action, on: current.isEmpty, tag: "", to: sub)
            sub.addItem(.separator())
            for name in Settings.sounds { item(name, nil, action, on: current == name, tag: name, to: sub) }
            item(title, symbol, nil).submenu = sub
        }
        item("Live Preview", "text.bubble", #selector(togglePreview), on: Settings.preview)
        item("Open at Login", "power", #selector(toggleLogin), on: SMAppService.mainApp.status == .enabled)
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "Quit Dictate", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        quit.image = NSImage(systemSymbolName: "xmark.rectangle", accessibilityDescription: nil)
    }

    @objc private func chooseStartSound(_ sender: NSMenuItem) { Settings.startSound = sender.representedObject as? String ?? ""; Voice.chime(Settings.startSound); voice.reset() }
    @objc private func chooseFinishSound(_ sender: NSMenuItem) { Settings.finishSound = sender.representedObject as? String ?? ""; Voice.chime(Settings.finishSound); voice.reset() }
    @objc private func togglePreview() { Settings.preview.toggle(); voice.reset() }
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
        if !CGPreflightPostEventAccess() { note("may not post keys yet; pasting is off until Accessibility is allowed") }
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
        if voice.failed { note("retry"); voice.retry(); return }
        if voice.active { voice.finish(); return }
        guard !voice.busy, let front = NSWorkspace.shared.frontmostApplication else { return }
        guard Logic.terminals.contains(front.bundleIdentifier ?? "") else { startPasting(into: front); return }
        startTerminal(front.localizedName ?? "the terminal", pane: nil, fallback: front, lookup: Task.detached {
            let clients = run(["tmux", "list-clients", "-F", "#{client_activity}\t#{pane_id}"])
            return Logic.activePane(clients: String(decoding: clients.out, as: UTF8.self)).flatMap(claudeSession)
        })
    }

    private func startPasting(into target: NSRunningApplication) {
        note("start → paste into \(target.bundleIdentifier ?? "?")")
        voice.onError = { [weak self] in self?.voice.flash($0) }
        voice.start(to: target.localizedName ?? "this app") { [weak self] text in self?.pasteOrKeep(text, into: target) }
    }

    /// Pastes only where a text box has focus; elsewhere ⌘V would drop the words without a trace, so they stay on the clipboard.
    private func pasteOrKeep(_ text: String, into target: NSRunningApplication) {
        let name = target.localizedName ?? "the app"
        let accepts = acceptsText(target)
        note("focus in \(target.bundleIdentifier ?? "?"): \(focusedRole(target) ?? "unknown")")
        if accepts == false {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            note("no text box in \(target.bundleIdentifier ?? "?"); left on the clipboard")
            voice.flash("No text box had focus in \(name); the words are on the clipboard")
            return
        }
        paste(text, into: target)
    }

    private func toggle(pane: String) {
        if voice.failed { note("retry"); voice.retry(); return }
        if voice.active { note("finish"); voice.finish(); return }
        guard !voice.busy else { note("busy transcribing; ignored"); return }
        startTerminal(pane, pane: pane, fallback: nil, lookup: Task.detached { claudeSession(in: pane) })
    }

    /// Records at once and finds the pane's Claude session while you talk, so starting never waits on `claude-say`.
    /// No session: the words are pasted into `fallback`, or with none the recording is dropped and the pane told why.
    private func startTerminal(_ label: String, pane: String?, fallback: NSRunningApplication?, lookup: Task<Session?, Never>) {
        note("start → \(label); finding its Claude session")
        voice.onError = { [weak self] in self?.voice.flash($0) }
        voice.start(to: label) { [weak self] text in
            Task { @MainActor in
                guard let self else { return }
                if let session = await lookup.value { self.deliver(text, to: session) } else if let fallback { self.pasteOrKeep(text, into: fallback) }
            }
        }
        Task { @MainActor [weak self] in
            let session = await lookup.value
            guard let self, self.voice.active else { return }
            if let session {
                note("→ \(session.session_id.prefix(8)) in \(session.pane)")
                self.voice.onError = { tell(session.pane, $0) }
                self.voice.retarget(session.topic.isEmpty ? session.pane : session.topic)
            } else if fallback == nil, let pane {
                note("no Claude session in \(pane)")
                tell(pane, "No Claude session in this pane to dictate to")
                self.voice.reset()
            }
        }
    }

    private func deliver(_ text: String, to session: Session) {
        Task.detached {
            let sent = run([claudeSay, session.session_id] + ["--draft", "--unsigned", text])
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

/// The Claude session `claude-say --json` places in `pane` (about 0.65s, which is why a recording doesn't wait for it).
func claudeSession(in pane: String) -> Session? {
    let listing = run([claudeSay, "--json"])
    return listing.status == 0 ? Logic.session(in: pane, listing: listing.out) : nil
}

/// The accessibility role of what has focus in `app`, for the log.
@MainActor
func focusedRole(_ app: NSRunningApplication) -> String? {
    var focused: CFTypeRef?, role: CFTypeRef?
    guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedUIElementAttribute as CFString, &focused) == .success,
          let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
    AXUIElementCopyAttributeValue(focused as! AXUIElement, kAXRoleAttribute as CFString, &role)
    return role as? String
}

/// Whether the focused element in `app` takes typed text, or nil when the app won't say.
@MainActor
func acceptsText(_ app: NSRunningApplication) -> Bool? {
    let root = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    var focused: CFTypeRef?
    guard AXUIElementCopyAttributeValue(root, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
          let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
    let field = focused as! AXUIElement
    var role: CFTypeRef?
    AXUIElementCopyAttributeValue(field, kAXRoleAttribute as CFString, &role)
    if let role = role as? String, [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, "AXSearchField"].contains(role) { return true }
    var settable: DarwinBoolean = false
    return AXUIElementIsAttributeSettable(field, kAXValueAttribute as CFString, &settable) == .success && settable.boolValue
}

/// Puts `text` into `target`: brought to the front, then inserted by Dictate Input (else pasted with ⌘V). The text stays
/// on the clipboard, so words that landed in the wrong place are one ⌘V from the right one.
@MainActor
func paste(_ text: String, into target: NSRunningApplication) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    let wasFront = target.isActive
    target.activate()
    DispatchQueue.main.asyncAfter(deadline: .now() + (wasFront ? 0.05 : 0.3)) {
        InputMethod.shared.insert(text, into: target.bundleIdentifier ?? "") { inserted in
            if !inserted { press(keyCode(typing: "v") ?? 9, flags: .maskCommand) }
            note(inserted ? "inserted" : "pasted")
        }
    }
}

/// Dictate Input, the input source in scripts/dictate-app/Sources/DictateInput: asked to insert words at the cursor of
/// an app's focused field, it answers with where they went. No answer within half a second (it isn't the input source,
/// or the field belongs to another app) means it didn't, and the caller pastes instead.
@MainActor
final class InputMethod: NSObject {
    static let shared = InputMethod()
    private var waiting: [String: (Bool) -> Void] = [:]

    override init() {
        super.init()
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(answered(_:)),
                                                            name: .init("com.philbrockman.dictate.inserted"), object: nil,
                                                            suspensionBehavior: .deliverImmediately)
    }

    func insert(_ text: String, into app: String, then done: @escaping (Bool) -> Void) {
        let request = UUID().uuidString
        waiting[request] = done
        DistributedNotificationCenter.default().postNotificationName(.init("com.philbrockman.dictate.insert"), object: request,
                                                                    userInfo: ["text": text, "app": app], deliverImmediately: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.waiting.removeValue(forKey: request)?(false) }
    }

    @objc private func answered(_ note: Notification) {
        guard let request = note.object as? String else { return }
        waiting.removeValue(forKey: request)?(!((note.userInfo?["into"] as? String) ?? "").isEmpty)
    }
}

private let lastFile = ("~/.cache/dictate/last.txt" as NSString).expandingTildeInPath

/// The words of the last finished recording, wherever they were sent.
func lastDictation() -> String? {
    (try? String(contentsOfFile: lastFile, encoding: .utf8)).flatMap { $0.isEmpty ? nil : $0 }
}

func rememberDictation(_ text: String) {
    try? text.write(toFile: lastFile, atomically: true, encoding: .utf8)
}

/// The key that types `character` in the current keyboard layout: on Dvorak, V sits where QWERTY has the period
/// and QWERTY's V key types K, so a fixed ⌘V key code opens Chrome's ⌘K menu instead of pasting.
func keyCode(typing character: String) -> CGKeyCode? {
    guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
          let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
    let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
    return data.withUnsafeBytes { bytes -> CGKeyCode? in
        guard let layout = bytes.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return nil }
        for code in CGKeyCode(0)..<128 {
            var dead: UInt32 = 0
            var length = 0
            var chars = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
                                        OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, chars.count, &length, &chars)
            if status == noErr, String(utf16CodeUnits: chars, count: length) == character { return code }
        }
        return nil
    }
}

/// One key press and release, posted as if typed (36 is Return in every layout).
func press(_ code: CGKeyCode, flags: CGEventFlags = []) {
    let source = CGEventSource(stateID: .combinedSessionState)
    for down in [true, false] {
        let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
        event?.flags = flags
        event?.post(tap: .cgSessionEventTap)
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
