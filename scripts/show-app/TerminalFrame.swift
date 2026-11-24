import AppKit

/// Ctrl-Space in tmux opens a link marked `beside=terminal` that names its pane: Show takes the terminal window's place and
/// size and comes forward at once, so the switch reads as one window changing what it shows, and canopy then goes to that
/// pane's branch. The terminal is whatever app the tmux client runs in (Terminal, Ghostty, …), as canopy has it from
/// `pane-branch host`; its window is never moved, and any other door into Show leaves its window as it is.
enum TerminalFrame {
    static let mark = URLQueryItem(name: "beside", value: "terminal")

    /// The link without the switch's words, whether it carried the mark, and the tmux pane id it named ("%12").
    static func unmarked(_ link: URL) -> (link: URL, beside: Bool, pane: String?) {
        guard var parts = URLComponents(url: link, resolvingAgainstBaseURL: false), let items = parts.queryItems, items.contains(mark) else {
            return (link, false, nil)
        }
        let pane = items.first { $0.name == "pane" }?.value.flatMap { Int($0) }.map { "%\($0)" }
        let rest = items.filter { $0 != mark && $0.name != "pane" }
        parts.queryItems = rest.isEmpty ? nil : rest
        return (parts.url ?? link, true, pane)
    }

    /// The frontmost ordinary window of the app `owner` among the window server's list (front to back), in AppKit's coordinates:
    /// the list measures from the main screen's top-left, AppKit from its bottom-left.
    static func frame(in windows: [[String: Any]], owner: pid_t, mainScreenHeight: CGFloat) -> NSRect? {
        for w in windows where w[kCGWindowOwnerPID as String] as? pid_t == owner && w[kCGWindowLayer as String] as? Int == 0 {
            guard let b = w[kCGWindowBounds as String] as? [String: Any],
                  let box = CGRect(dictionaryRepresentation: b as CFDictionary), box.width >= 300, box.height >= 200 else { continue }
            return NSRect(x: box.minX, y: mainScreenHeight - box.maxY, width: box.width, height: box.height)
        }
        return nil
    }

    static func current(owner: pid_t) -> NSRect? {
        guard let height = NSScreen.screens.first?.frame.height,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        return frame(in: windows, owner: owner, mainScreenHeight: height)
    }
}

extension AppDelegate {
    func takeTerminalFrame() {
        guard snapshotPath == nil, selfTest == nil, let window, !window.styleMask.contains(.fullScreen),
              let owner = workspaces[.canopy]?.canopy?.terminalHost, let frame = TerminalFrame.current(owner: owner), frame != window.frame else { return }
        window.setFrame(frame, display: true)
    }
}
