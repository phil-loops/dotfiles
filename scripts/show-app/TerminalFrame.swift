import AppKit

/// Ctrl-Space in tmux comes over to canopy (`pane-branch canopy`) with a link marked `beside=terminal`: Show then takes the
/// Terminal window's place and size, so the switch reads as one window changing what it shows. Terminal is never moved, and
/// any other door into Show leaves its window as it is.
enum TerminalFrame {
    static let mark = URLQueryItem(name: "beside", value: "terminal")

    /// The link without the mark, and whether it carried one.
    static func unmarked(_ link: URL) -> (link: URL, beside: Bool) {
        guard var parts = URLComponents(url: link, resolvingAgainstBaseURL: false), let items = parts.queryItems, items.contains(mark) else {
            return (link, false)
        }
        let rest = items.filter { $0 != mark }
        parts.queryItems = rest.isEmpty ? nil : rest
        return (parts.url ?? link, true)
    }

    /// Terminal's frontmost ordinary window among the window server's list (front to back), in AppKit's coordinates:
    /// the list measures from the main screen's top-left, AppKit from its bottom-left.
    static func frame(in windows: [[String: Any]], mainScreenHeight: CGFloat) -> NSRect? {
        for w in windows where w[kCGWindowOwnerName as String] as? String == "Terminal" && w[kCGWindowLayer as String] as? Int == 0 {
            guard let b = w[kCGWindowBounds as String] as? [String: Any],
                  let box = CGRect(dictionaryRepresentation: b as CFDictionary), box.width >= 300, box.height >= 200 else { continue }
            return NSRect(x: box.minX, y: mainScreenHeight - box.maxY, width: box.width, height: box.height)
        }
        return nil
    }

    static func current() -> NSRect? {
        guard let height = NSScreen.screens.first?.frame.height,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        return frame(in: windows, mainScreenHeight: height)
    }
}

extension AppDelegate {
    func takeTerminalFrame() {
        guard snapshotPath == nil, selfTest == nil, let window, !window.styleMask.contains(.fullScreen),
              let frame = TerminalFrame.current(), frame != window.frame else { return }
        window.setFrame(frame, display: true)
    }
}
