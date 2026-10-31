import AppKit
import CanopyCore

/// The one keyDown listener: every key press becomes a key name for the KeyEngine, which runs it
/// through the live mode's keymap. Pages never install key handlers of their own.
///
/// Text entry (insert, the `:` line, the menu's and picker's filters): the engine gets each key
/// first and keeps the ones bound in that mode (esc, ret, C-n, …); anything else goes on to the
/// focused field. Clicking into an editable field enters insert mode. A read-only text view (the
/// CodeTextView) never owns the keyboard. ⌘ shortcuts are never page keys; they go to the menu bar.
@MainActor
final class KeyMonitor {
    private var token: Any?
    private weak var app: AppModel?
    /// Inside a host app: whether this event is canopy's at all (nil: every event is).
    private let owns: ((NSEvent) -> Bool)?

    init(app: AppModel, owns: ((NSEvent) -> Bool)? = nil) { self.app = app; self.owns = owns }

    func install() {
        guard token == nil else { return }
        token = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { [weak self] e in
            guard let self, let app = self.app, self.owns?(e) ?? true else { return e }
            if e.type == .leftMouseDown {
                app.keys.reset()
                return e
            }
            return self.key(e, app) ? nil : e
        }
    }

    /// true: the key was the engine's, swallow it.
    private func key(_ e: NSEvent, _ app: AppModel) -> Bool {
        let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let field = e.window?.firstResponder as? NSTextView
        let editing = field?.isEditable == true
        // the engine keys really reach: the keytutor's practice app while it's up
        let keys = app.keys.innermost
        if editing && !keys.textEntry {
            keys.setMode(.insert)
            // clicked into: a field editor is a one-line field, a bare text view a many-line box
            keys.fieldLines = field?.isFieldEditor == true ? .single : .multi
        }
        guard let name = KeyName.name(keyCode: e.keyCode, characters: e.characters, charactersIgnoringModifiers: e.charactersIgnoringModifiers,
                                      ctrl: mods.contains(.control), meta: mods.contains(.command), alt: mods.contains(.option))
        else { return false }
        let took = app.keys.handle(name)
        if !app.keys.innermost.textEntry, editing { e.window?.makeFirstResponder(nil) }
        return took
    }
}
