import AppKit
import Carbon
import InputMethodKit

/// Dictate Input: the input source that puts Dictate's words into the focused text field the way macOS's own dictation
/// does — inserted through the text system, with no keystroke and no clipboard. Every key passes through untouched, typed
/// with the keyboard layout you used before choosing it. Dictate asks over a distributed notification; the reply says
/// whether the words went in, so Dictate can paste instead when they didn't.
@objc(DictateInputController)
final class DictateInputController: IMKInputController {
    nonisolated(unsafe) static weak var current: DictateInputController?

    override func activateServer(_ sender: Any!) {
        DictateInputController.current = self
        if let layout = typingLayout(), let client = sender as? IMKTextInput { client.overrideKeyboard(withKeyboardNamed: layout) }
    }

    override func deactivateServer(_ sender: Any!) {
        if DictateInputController.current === self { DictateInputController.current = nil }
    }

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool { false }
}

/// The ASCII keyboard layout last in use (Dvorak, say), which keys type with while Dictate Input is the input source.
func typingLayout() -> String? {
    guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
          let id = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
    return Unmanaged<CFString>.fromOpaque(id).takeUnretainedValue() as String
}

/// Inserts `text` at the cursor of the focused field, only when that field belongs to `app` (the app Dictate meant).
func insertAtCursor(_ text: String, into app: String) -> String? {
    guard let client = DictateInputController.current?.client() else { return nil }
    guard client.bundleIdentifier() == app else { return nil }
    client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
    return client.bundleIdentifier()
}

/// Registers, enables and selects Dictate Input as the input source (run once by `dictate` after installing it).
func install(_ bundle: URL) -> Int32 {
    TISRegisterInputSource(bundle as CFURL)
    let filter = [kTISPropertyBundleID as String: Bundle(url: bundle)?.bundleIdentifier ?? ""] as CFDictionary
    guard let sources = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource], !sources.isEmpty else {
        FileHandle.standardError.write(Data("dictate-input: macOS didn't register the input source\n".utf8))
        return 1
    }
    for source in sources {
        TISEnableInputSource(source)
        TISSelectInputSource(source)
    }
    return 0
}

/// The input menu's icon: the mic symbol, as a template TIFF.
func renderIcon(to path: String) -> Int32 {
    guard let symbol = NSImage(systemSymbolName: "mic", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 13, weight: .regular)) else { return 1 }
    let size = NSSize(width: 16, height: 16)
    let image = NSImage(size: size, flipped: false) { rect in
        let fit = symbol.size
        symbol.draw(in: NSRect(x: (rect.width - fit.width) / 2, y: (rect.height - fit.height) / 2, width: fit.width, height: fit.height))
        return true
    }
    image.isTemplate = true
    guard let tiff = image.tiffRepresentation, (try? tiff.write(to: URL(fileURLWithPath: path))) != nil else { return 1 }
    return 0
}

let arguments = CommandLine.arguments
if let at = arguments.firstIndex(of: "--render-icon"), at + 1 < arguments.count { exit(renderIcon(to: arguments[at + 1])) }
if let at = arguments.firstIndex(of: "--install"), at + 1 < arguments.count { exit(install(URL(fileURLWithPath: arguments[at + 1]))) }

let info = Bundle.main.infoDictionary ?? [:]
let server = IMKServer(name: info["InputMethodConnectionName"] as? String, bundleIdentifier: Bundle.main.bundleIdentifier)
/// Answers Dictate's requests; delivered at once even though an input method's process is never the active app.
final class Requests: NSObject {
    @objc func insert(_ note: Notification) {
        guard let request = note.object as? String,
              let body = note.userInfo, let text = body["text"] as? String, let app = body["app"] as? String else { return }
        let into = insertAtCursor(text, into: app)
        DistributedNotificationCenter.default().postNotificationName(.init("com.philbrockman.dictate.inserted"), object: request,
                                                                    userInfo: ["into": into ?? ""], deliverImmediately: true)
    }
}
let requests = Requests()
DistributedNotificationCenter.default().addObserver(requests, selector: #selector(Requests.insert(_:)),
                                                    name: .init("com.philbrockman.dictate.insert"), object: nil,
                                                    suspensionBehavior: .deliverImmediately)
NSApplication.shared.run()
