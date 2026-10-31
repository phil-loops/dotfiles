import AppKit
import WebKit

/// When a key does anything, beyond its workspace: whatever has focus, outside text fields, or with a list focused.
enum KeyWhen {
    case always, notTyping, inList, onShelf
}

/// One action and its key. Keys with ⌘, ⌃ or ⌥ fire through their menu item; bare keys (j, /, ⇥, ⎋) through the window's key router.
/// Either way the binding shows in its menu with the shortcut and in the `?` sheet.
struct KeyBinding {
    let id: String
    let menu: String
    let title: String
    let key: String
    var modifiers: NSEvent.ModifierFlags = []
    /// The workspaces it belongs to; nil means every workspace.
    var workspaces: [Workspace]? = nil
    var when: KeyWhen = .always
    /// Another key that does the same, named in the `?` sheet only (↓ beside j).
    var also: String? = nil
    /// Whether it still works while the finder, the key sheet or the New… prompt covers the window.
    var overOverlay = false
    /// False for a second key to an action already listed (its `also` names it): it routes, but gets no menu item or sheet row.
    var listed = true
    var isEnabled: (AppDelegate) -> Bool = { _ in true }
    let perform: (AppDelegate) -> Void

    /// Bare keys (Shift aside) go through the router, since a menu only fires keys that carry ⌘, ⌃ or ⌥.
    var isRouted: Bool { modifiers.intersection([.command, .control, .option]).isEmpty }

    func applies(in workspace: Workspace) -> Bool {
        workspaces?.contains(workspace) ?? true
    }

    var glyphs: String {
        var out = ""
        if modifiers.contains(.control) { out += "⌃" }
        if modifiers.contains(.option) { out += "⌥" }
        if modifiers.contains(.shift) { out += "⇧" }
        if modifiers.contains(.command) { out += "⌘" }
        return out + keyGlyph(key)
    }

    /// Whether `event` is this binding's key with exactly its modifiers.
    func matches(_ event: NSEvent) -> Bool {
        let held = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if let code = specialKeyCodes[key] {
            return code.contains(event.keyCode) && held == modifiers
        }
        guard let typed = event.charactersIgnoringModifiers?.lowercased(), !typed.isEmpty else { return false }
        let letter = key.first?.isLetter == true
        let compared = letter ? held : held.subtracting(.shift)
        return typed == key.lowercased() && compared == modifiers.subtracting(letter ? [] : .shift)
    }
}

/// Keys that arrive as key codes rather than characters.
let specialKeyCodes: [String: [UInt16]] = [
    "\t": [48], "\r": [36, 76], "\u{1b}": [53], "\u{8}": [51, 117],
    String(UnicodeScalar(NSDownArrowFunctionKey)!): [125], String(UnicodeScalar(NSUpArrowFunctionKey)!): [126],
]

func keyGlyph(_ key: String) -> String {
    switch key {
    case "\t": return "⇥"
    case "\r": return "↩"
    case "\u{1b}": return "⎋"
    case "\u{8}": return "⌫"
    case String(UnicodeScalar(NSDownArrowFunctionKey)!): return "↓"
    case String(UnicodeScalar(NSUpArrowFunctionKey)!): return "↑"
    default: return key.uppercased()
    }
}

/// The one list of keys: the menu bar and the `?` sheet are both generated from it.
/// Other areas append theirs with `KeyTable.register([...])` (from their controller's init is fine); the menus rebuild themselves.
enum KeyTable {
    static let menuOrder = ["Library", "Go", "Section", "Workspace", "Tutor", "Runs", "Help"]
    private(set) static var bindings: [KeyBinding] = core
    static var onChange: (() -> Void)?

    static func register(_ added: [KeyBinding]) {
        let ids = Set(added.map(\.id))
        bindings = bindings.filter { !ids.contains($0.id) } + added
        onChange?()
    }

    static func binding(_ id: String) -> KeyBinding? {
        bindings.first { $0.id == id }
    }

    static var menus: [String] {
        let named = Set(bindings.map(\.menu))
        return menuOrder.filter(named.contains) + named.subtracting(menuOrder).sorted()
    }

    static let core: [KeyBinding] = [
        KeyBinding(id: "library.find", menu: "Library", title: "Find…", key: "o", modifiers: .command, also: "/", overOverlay: true) { $0.showFinder(nil) },
        KeyBinding(id: "library.find-slash", menu: "Library", title: "Find…", key: "/", when: .notTyping, listed: false) { $0.showFinder(nil) },
        KeyBinding(id: "library.new", menu: "Library", title: "New…", key: "n", modifiers: .command, workspaces: [.forest, .review]) { $0.showNewPrompt() },
        KeyBinding(id: "library.new-runs", menu: "Library", title: "New… (off: runs start from their own scripts)", key: "n", modifiers: .command, workspaces: [.runs],
                   isEnabled: { _ in false }) { _ in },
        KeyBinding(id: "library.open-file", menu: "Library", title: "Open File…", key: "o", modifiers: [.command, .option]) { $0.openOther(nil) },
        KeyBinding(id: "library.back", menu: "Library", title: "Back", key: "[", modifiers: .command,
                   isEnabled: { $0.workspaces[$0.active]?.back.isEmpty == false }) { $0.goBack(nil) },
        KeyBinding(id: "library.archive", menu: "Library", title: "Archive Shelf Row", key: "\u{8}", when: .onShelf,
                   isEnabled: { $0.workspaces[$0.active].map { $0.shelf.selectedRow >= 0 } ?? false }) { $0.archiveSelected(nil) },
        KeyBinding(id: "library.reload", menu: "Library", title: "Reload", key: "r", modifiers: .command) { $0.reloadCurrent(nil) },
        KeyBinding(id: "library.toggle-shelf", menu: "Library", title: "Toggle Shelf", key: "s", modifiers: [.command, .control]) { $0.toggleShelf(nil) },

        KeyBinding(id: "go.next-column", menu: "Go", title: "Next Column", key: "\t") { $0.cycleFocus(1) },
        KeyBinding(id: "go.previous-column", menu: "Go", title: "Previous Column", key: "\t", modifiers: .shift) { $0.cycleFocus(-1) },
        KeyBinding(id: "go.next-row", menu: "Go", title: "Next in List", key: "j", when: .inList, also: "↓") { $0.stepList(1) },
        KeyBinding(id: "go.previous-row", menu: "Go", title: "Previous in List", key: "k", when: .inList, also: "↑") { $0.stepList(-1) },
        KeyBinding(id: "go.open", menu: "Go", title: "Open Selected", key: "\r", when: .inList) { $0.openFocused() },
        KeyBinding(id: "go.write", menu: "Go", title: "Write Note", key: "n", when: .notTyping,
                   isEnabled: { $0.composerStop != nil }) { $0.focusComposer() },
        KeyBinding(id: "go.leave", menu: "Go", title: "Leave Field or Close", key: "\u{1b}", overOverlay: true) { $0.escape() },

        KeyBinding(id: "section.sign", menu: "Section", title: "Toggle Signed Off", key: "s", modifiers: .command, workspaces: [.forest, .review],
                   isEnabled: { $0.signableDeck != nil }) { $0.toggleSignedOff() },
        KeyBinding(id: "section.submit", menu: "Section", title: "Send Reply or Submit", key: "\r", modifiers: .command, workspaces: [.forest, .review],
                   isEnabled: { $0.signableDeck != nil }) { $0.sendOrSubmit() },
        KeyBinding(id: "section.canopy", menu: "Section", title: "Open Branch in Canopy", key: "O", modifiers: [.command, .shift], workspaces: [.forest]) { $0.openInCanopy(nil) },

        KeyBinding(id: "workspace.forest", menu: "Workspace", title: "Forest", key: "1", modifiers: .command, overOverlay: true) { $0.switchTo(.forest) },
        KeyBinding(id: "workspace.review", menu: "Workspace", title: "Review", key: "2", modifiers: .command, overOverlay: true) { $0.switchTo(.review) },
        KeyBinding(id: "workspace.learn", menu: "Workspace", title: "Learn", key: "3", modifiers: .command, overOverlay: true) { $0.switchTo(.learn) },
        KeyBinding(id: "workspace.runs", menu: "Workspace", title: "Runs", key: "4", modifiers: .command, overOverlay: true) { $0.switchTo(.runs) },
        KeyBinding(id: "workspace.api", menu: "Workspace", title: "API", key: "5", modifiers: .command, overOverlay: true) { $0.switchTo(.api) },

        KeyBinding(id: "tutor.send", menu: "Tutor", title: "Send", key: "\r", modifiers: .command, workspaces: [.learn]) { $0.tutor?.sendFocused() },
        KeyBinding(id: "tutor.guessing", menu: "Tutor", title: confidenceLevels[0].1, key: "1", modifiers: .control, workspaces: [.learn],
                   isEnabled: { $0.tutor?.currentRungID != nil }) { $0.tutor?.choose(confidence: 0) },
        KeyBinding(id: "tutor.fairly-sure", menu: "Tutor", title: confidenceLevels[1].1, key: "2", modifiers: .control, workspaces: [.learn],
                   isEnabled: { $0.tutor?.currentRungID != nil }) { $0.tutor?.choose(confidence: 1) },
        KeyBinding(id: "tutor.certain", menu: "Tutor", title: confidenceLevels[2].1, key: "3", modifiers: .control, workspaces: [.learn],
                   isEnabled: { $0.tutor?.currentRungID != nil }) { $0.tutor?.choose(confidence: 2) },
        KeyBinding(id: "tutor.retry", menu: "Tutor", title: "Retry Tutor Turn", key: "r", modifiers: [.command, .shift], workspaces: [.learn],
                   isEnabled: { $0.tutor?.agent?.failure != nil }) { $0.tutor?.agent?.retry() },

        KeyBinding(id: "runs.only-differing", menu: "Runs", title: "Only Rows That Differ", key: "d", workspaces: [.runs], when: .notTyping,
                   isEnabled: { $0.workspaces[.runs]?.currentDeck?.selectedSection?.compare != nil }) { $0.workspaces[.runs]?.currentDeck?.toggleOnlyDifferingRows() },
        KeyBinding(id: "runs.stop", menu: "Runs", title: "Stop After This Round…", key: ".", modifiers: .command, workspaces: [.runs],
                   isEnabled: { $0.workspaces[.runs]?.currentDeck?.live.stop.isEnabled == true }) { $0.workspaces[.runs]?.currentDeck?.live.confirmStop() },

        KeyBinding(id: "help.keys", menu: "Help", title: "Keyboard Shortcuts", key: "/", modifiers: .command, also: "?", overOverlay: true) { $0.toggleKeySheet() },
        KeyBinding(id: "help.keys-question", menu: "Help", title: "Keyboard Shortcuts", key: "?", when: .notTyping, overOverlay: true, listed: false) { $0.toggleKeySheet() },
    ]
}

/// The one window. Bare keys go through `onKeyDown` (the key router) before AppKit sees them, and every focus change is reported,
/// so the focused column's outline follows it.
final class ShowWindow: NSWindow {
    var onKeyDown: ((NSEvent) -> Bool)?
    var onFocusChange: (() -> Void)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, onKeyDown?(event) == true { return }
        super.sendEvent(event)
    }

    /// The self-test parks the window far offscreen; a titled window would otherwise be pulled back onto a screen.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        selfTest == nil ? super.constrainFrameRect(frameRect, to: screen) : frameRect
    }

    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        let made = super.makeFirstResponder(responder)
        onFocusChange?()
        return made
    }
}

/// A place Tab can land: the view that takes focus, and the column the accent outline goes around while it has it.
struct FocusStop {
    let responder: NSView
    let column: NSView
}

extension WorkspaceController {
    /// Tab's order in this workspace: shelf → section list → detail → composer. Hidden or collapsed columns are skipped.
    var focusStops: [FocusStop] {
        var stops: [FocusStop] = []
        if let shelfItem = split.splitViewItems.first, !shelfItem.isCollapsed {
            stops.append(FocusStop(responder: shelf, column: shelfItem.viewController.view))
        }
        if let tutor, current != nil {
            if let list = tutor.viewController.splitViewItems.first, !list.isCollapsed {
                stops.append(FocusStop(responder: tutor.sidebar.table, column: list.viewController.view))
            }
            stops += tutor.fields.map { FocusStop(responder: $0, column: tutor.scroll) }
            stops.append(FocusStop(responder: tutor.composer, column: tutor.composer.superview?.superview ?? tutor.composer))
        } else if let deck = currentDeck {
            if let list = deck.viewController.splitViewItems.first, !list.isCollapsed {
                stops.append(FocusStop(responder: deck.table, column: list.viewController.view))
            }
            let page = deck.web.isHidden ? deck.text as NSView : deck.web
            stops.append(FocusStop(responder: page, column: deck.textScroll.superview ?? page))
            if !deck.actionBar.isHidden {
                stops.append(FocusStop(responder: deck.composer, column: deck.actionBar))
            }
        }
        return stops.filter { !$0.responder.isHiddenOrHasHiddenAncestor }
    }
}

/// The accent outline around whichever column has keyboard focus; it never takes clicks.
final class FocusOutline: NSView {
    weak var target: NSView? { didSet { needsDisplay = true } }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let target, target.window === window, !target.isHiddenOrHasHiddenAncestor else { return }
        let frame = target.convert(target.bounds, to: self).insetBy(dx: 1.5, dy: 1.5)
        let shape = NSBezierPath(roundedRect: frame, xRadius: 5, yRadius: 5)
        shape.lineWidth = 2
        NSColor.controlAccentColor.withAlphaComponent(0.55).setStroke()
        shape.stroke()
    }
}

extension AppDelegate {
    var showWindow: ShowWindow? { window as? ShowWindow }

    /// Whether keystrokes are going into a text field, where `j` and `/` are just letters.
    var isTyping: Bool {
        if let view = window.firstResponder as? NSView, sequence(first: view, next: \.superview).contains(where: { $0 is WKWebView }) {
            return true
        }
        guard let responder = window.firstResponder as? NSTextView else { return false }
        return responder.isEditable
    }

    /// The open sign-off deck in Forest or Review, the one ⌘S and ⌘↩ act on.
    var signableDeck: DeckController? {
        guard active == .forest || active == .review, let deck = workspaces[active]?.currentDeck, !deck.deck.isLive else { return nil }
        return deck
    }

    func isEnabled(_ binding: KeyBinding) -> Bool {
        guard binding.applies(in: active) else { return false }
        if shell.overlay != nil || shell.finder != nil, !binding.overOverlay { return false }
        switch binding.when {
        case .always: break
        case .notTyping: if isTyping { return false }
        case .inList: if !(window.firstResponder is NSTableView) { return false }
        case .onShelf: if window.firstResponder !== workspaces[active]?.shelf { return false }
        }
        return binding.isEnabled(self)
    }

    /// The window's key router: a bare key that belongs to an enabled binding runs it and goes no further.
    func route(_ event: NSEvent) -> Bool {
        guard let binding = KeyTable.bindings.first(where: { $0.isRouted && $0.matches(event) && isEnabled($0) }) else { return false }
        binding.perform(self)
        return true
    }

    @objc func runBinding(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let binding = KeyTable.binding(id), isEnabled(binding) else { return }
        binding.perform(self)
    }

    /// The menu bar, generated from `KeyTable`: a menu per binding group, then the standard Edit and Window menus.
    func installMenus() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Show", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        for name in KeyTable.menus {
            let item = NSMenuItem()
            let menu = NSMenu(title: name)
            for binding in KeyTable.bindings where binding.menu == name && binding.listed {
                let entry = NSMenuItem(title: binding.title, action: #selector(runBinding), keyEquivalent: binding.key)
                entry.keyEquivalentModifierMask = binding.modifiers.subtracting(binding.key.first?.isLetter == true && binding.key == binding.key.uppercased() ? .shift : [])
                entry.representedObject = binding.id
                entry.target = self
                menu.addItem(entry)
            }
            item.submenu = menu
            main.addItem(item)
            if name == "Help" { NSApp.helpMenu = menu }
        }
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.insertItem(editItem, at: 1)
        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = main
        scopeMenus()
    }

    /// Hides the items that don't belong to the front workspace (a hidden item never answers its key), and a menu left empty.
    func scopeMenus() {
        for top in NSApp.mainMenu?.items ?? [] {
            guard let menu = top.submenu, KeyTable.menus.contains(menu.title) else { continue }
            for item in menu.items {
                guard let id = item.representedObject as? String, let binding = KeyTable.binding(id) else { continue }
                item.isHidden = !binding.applies(in: active)
            }
            top.isHidden = menu.items.allSatisfy(\.isHidden)
        }
    }

    // MARK: focus

    /// Wires the window's key router and focus reports, and lays the focus outline over the shell.
    func installKeys() {
        showWindow?.onKeyDown = { [weak self] event in self?.route(event) ?? false }
        showWindow?.onFocusChange = { [weak self] in self?.updateFocusOutline() }
        KeyTable.onChange = { [weak self] in
            DispatchQueue.main.async { if NSApp.mainMenu != nil { self?.installMenus() } }
        }
        let outline = FocusOutline()
        pinned(outline, in: shell.view)
        shell.focusOutline = outline
        for name in [NSSplitView.didResizeSubviewsNotification, NSWindow.didResizeNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.shell.focusOutline?.needsDisplay = true
            }
        }
    }

    var focusStops: [FocusStop] { workspaces[active]?.focusStops ?? [] }

    /// The stop holding the first responder: the view itself, or the text field whose field editor is typing.
    func currentStop() -> Int? {
        var responder = window.firstResponder
        if let editor = responder as? NSTextView, editor.isFieldEditor, let field = editor.delegate as? NSTextField {
            responder = field
        }
        guard let view = responder as? NSView else { return nil }
        return focusStops.firstIndex { view === $0.responder || view.isDescendant(of: $0.responder) }
    }

    func updateFocusOutline() {
        guard let outline = shell?.focusOutline else { return }
        let stops = focusStops
        outline.target = currentStop().map { stops[$0].column }
    }

    /// ⇥ / ⇧⇥: the next or previous column in shelf → section list → detail → composer order, wrapping around.
    func cycleFocus(_ step: Int) {
        let stops = focusStops
        guard !stops.isEmpty else { return }
        let next = currentStop().map { ($0 + step + stops.count) % stops.count } ?? (step > 0 ? 0 : stops.count - 1)
        focus(stops[next].responder)
    }

    func focus(_ view: NSView) {
        window.makeFirstResponder(view)
        if let field = view as? NSTextField, let editor = field.currentEditor() {
            editor.selectedRange = NSRange(location: (editor.string as NSString).length, length: 0)
        }
        if let table = view as? NSTableView, table.selectedRow < 0,
           let first = (0..<table.numberOfRows).first(where: { table.delegate?.tableView?(table, shouldSelectRow: $0) ?? true }) {
            table.selectRowIndexes(IndexSet(integer: first), byExtendingSelection: false)
        }
        updateFocusOutline()
    }

    /// j / k: the focused list's next or previous row, exactly as ↓ / ↑ would move it.
    func stepList(_ step: Int) {
        guard let table = window.firstResponder as? NSTableView else { return }
        let arrow = step > 0 ? NSDownArrowFunctionKey : NSUpArrowFunctionKey
        let characters = String(UnicodeScalar(arrow)!)
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .numericPad, timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                           isARepeat: false, keyCode: step > 0 ? 125 : 126) else { return }
        table.keyDown(with: event)
    }

    /// ↵ in a list: on the shelf it opens the row (or unfolds Done) and moves into the document; in the section list it moves to the page.
    func openFocused() {
        guard let controller = workspaces[active], let table = window.firstResponder as? NSTableView else { return }
        let stops = focusStops
        if table === controller.shelf {
            if controller.activateSelectedShelfRow() { return }
            if let next = stops.first(where: { $0.responder !== controller.shelf }) {
                focus(next.responder)
            }
        } else if table === controller.tutor?.sidebar.table, controller.tutor?.sidebar.activateSelected() == true {
            return
        } else if let index = stops.firstIndex(where: { $0.responder === table }), index + 1 < stops.count {
            focus(stops[index + 1].responder)
        }
    }

    /// The note (Forest, Review) or the composer (Learn) that `n` jumps into.
    var composerStop: NSView? {
        guard let controller = workspaces[active] else { return nil }
        if let tutor = controller.tutor, controller.current != nil { return tutor.composer }
        guard let deck = controller.currentDeck, !deck.actionBar.isHidden else { return nil }
        return deck.composer
    }

    func focusComposer() {
        if let view = composerStop { focus(view) }
    }

    /// ⌘↩: sends the reply being typed, otherwise submits the deck.
    func sendOrSubmit() {
        guard let deck = signableDeck else { return }
        if window.firstResponder === deck.composer, !deck.composer.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            deck.sendMessage()
        } else {
            deck.submit.performClick(nil)
        }
    }

    func toggleSignedOff() {
        guard let deck = signableDeck, deck.selectedSection != nil else { return }
        deck.signed.performClick(nil)
    }

    /// ⎋: closes whatever covers the window, otherwise steps out of a text field into its column's list. Typed text always stays.
    func escape() {
        if shell.overlay != nil || shell.finder != nil {
            closeOverlays()
            return
        }
        guard isTyping, let controller = workspaces[active] else { return }
        window.makeFirstResponder(nil)
        if let deck = controller.currentDeck, !deck.table.isHiddenOrHasHiddenAncestor {
            focus(deck.table)
        } else {
            focus(controller.shelf)
        }
    }

    func closeOverlays() {
        shell.hideOverlay()
        if shell.finder != nil {
            shell.hideFinder()
        }
        workspaces[active]?.restoreFocus(in: window)
        updateFocusOutline()
    }

    // MARK: the key sheet

    func toggleKeySheet() {
        if shell.overlay is KeySheetOverlay {
            closeOverlays()
            return
        }
        closeOverlays()
        workspaces[active]?.rememberFocus(in: window)
        let sheet = KeySheetOverlay(bindings: KeyTable.bindings, active: active)
        sheet.onClose = { [weak self] in self?.closeOverlays() }
        shell.showOverlay(sheet)
        window.makeFirstResponder(sheet)
        updateFocusOutline()
    }
}

/// The `?` sheet: every key in `KeyTable`, Everywhere in the left column and each workspace's own on the right, the front one marked.
final class KeySheetOverlay: NSView {
    let panel = NSVisualEffectView()
    var onClose: (() -> Void)?

    init(bindings: [KeyBinding], active: Workspace) {
        super.init(frame: .zero)
        panel.material = .popover
        panel.state = .active
        panel.wantsLayer = true
        panel.layer?.cornerRadius = 10
        panel.layer?.masksToBounds = true
        let groups = Self.groups(bindings.filter(\.listed))
        let title = NSTextField(labelWithString: "Keys")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        let hint = NSTextField(labelWithString: "? or ⎋ closes")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        let left = Self.column(groups.filter { $0.workspace == nil }, active: active)
        let right = Self.column(groups.filter { $0.workspace != nil }, active: active)
        for view in [panel, title, hint, left, right] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        addSubview(panel)
        [title, hint, left, right].forEach(panel.addSubview)
        NSLayoutConstraint.activate([
            panel.centerXAnchor.constraint(equalTo: centerXAnchor),
            panel.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -10),
            panel.widthAnchor.constraint(equalToConstant: 760),
            title.topAnchor.constraint(equalTo: panel.topAnchor, constant: 18),
            title.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 24),
            hint.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
            hint.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -24),
            left.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
            left.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 8),
            left.widthAnchor.constraint(equalToConstant: 370),
            right.topAnchor.constraint(equalTo: left.topAnchor),
            right.leadingAnchor.constraint(equalTo: left.trailingAnchor, constant: 4),
            right.widthAnchor.constraint(equalToConstant: 370),
            panel.bottomAnchor.constraint(greaterThanOrEqualTo: left.bottomAnchor, constant: 18),
            panel.bottomAnchor.constraint(greaterThanOrEqualTo: right.bottomAnchor, constant: 18),
            panel.bottomAnchor.constraint(equalTo: left.bottomAnchor).withPriority(.defaultLow),
        ])
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.12).setFill()
        bounds.intersection(dirtyRect).fill()
    }

    override func mouseDown(with event: NSEvent) {
        if !panel.frame.contains(convert(event.locationInWindow, from: nil)) {
            onClose?()
        }
    }

    /// The groups the sheet shows, in order: bindings for every workspace, then each workspace's own.
    static func groups(_ bindings: [KeyBinding]) -> [(name: String, workspace: Workspace?, bindings: [KeyBinding])] {
        var out: [(String, Workspace?, [KeyBinding])] = [("Everywhere", nil, bindings.filter { $0.workspaces == nil })]
        for workspace in Workspace.allCases {
            let own = bindings.filter { $0.workspaces?.contains(workspace) == true }
            if !own.isEmpty { out.append((workspace.name, workspace, own)) }
        }
        return out
    }

    private static func column(_ groups: [(name: String, workspace: Workspace?, bindings: [KeyBinding])], active: Workspace) -> NSTextField {
        let label = NSTextField(labelWithAttributedString: sheet(groups, active: active))
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        return label
    }

    static func sheet(_ groups: [(name: String, workspace: Workspace?, bindings: [KeyBinding])], active: Workspace) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let row = NSMutableParagraphStyle()
        row.tabStops = [NSTextTab(textAlignment: .right, location: 74), NSTextTab(textAlignment: .left, location: 90)]
        row.lineSpacing = 3
        for group in groups {
            let heading = NSMutableParagraphStyle()
            heading.paragraphSpacingBefore = 12
            heading.paragraphSpacing = 3
            heading.firstLineHeadIndent = 16
            out.append(NSAttributedString(string: group.name, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: heading]))
            if group.workspace == active {
                out.append(NSAttributedString(string: "  · here", attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: active.tint(), .paragraphStyle: heading]))
            }
            out.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: heading]))
            for binding in group.bindings {
                let keys = binding.glyphs + (binding.also.map { "  " + $0 } ?? "")
                out.append(NSAttributedString(string: "\t\(keys)\t", attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.labelColor, .paragraphStyle: row]))
                out.append(NSAttributedString(string: binding.title + "\n", attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor, .paragraphStyle: row]))
            }
        }
        if out.length > 0 { out.deleteCharacters(in: NSRange(location: out.length - 1, length: 1)) }
        return out
    }
}

extension NSLayoutConstraint {
    func withPriority(_ priority: NSLayoutConstraint.Priority) -> NSLayoutConstraint {
        self.priority = priority
        return self
    }
}
