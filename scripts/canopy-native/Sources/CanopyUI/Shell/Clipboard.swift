import AppKit

/// The clipboard every copy goes through. Under a test runner it's a private pasteboard, so a
/// test's `y` never replaces what's on the real clipboard (2026-11-02: a test's canopy:// link
/// was left there and the next paste opened it).
public enum Clipboard {
    nonisolated(unsafe) public static var board: NSPasteboard =
        underTest ? NSPasteboard(name: NSPasteboard.Name("canopy-tests")) : .general

    /// `swift test` runs the suite in swiftpm-testing-helper; Xcode loads it as a .xctest bundle.
    static var underTest: Bool {
        ProcessInfo.processInfo.processName == "swiftpm-testing-helper"
            || Bundle.allBundles.contains { $0.bundlePath.hasSuffix(".xctest") }
    }

    public static func copy(_ s: String) {
        board.clearContents()
        board.setString(s, forType: .string)
    }

    public static var text: String? { board.string(forType: .string) }
}
