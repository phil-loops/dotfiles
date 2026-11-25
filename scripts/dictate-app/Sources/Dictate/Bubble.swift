import AppKit

/// The words heard so far, in a small floating box: near the bottom of the screen the pointer is on, or wherever it was last
/// dragged. It never takes focus, so typing carries on in the app underneath.
@MainActor
final class Bubble {
    private let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 60),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    private let label = NSTextField(wrappingLabelWithString: "")

    init() {
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        let backdrop = NSVisualEffectView()
        backdrop.material = .hudWindow
        backdrop.state = .active
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = 14
        backdrop.layer?.masksToBounds = true
        label.font = .systemFont(ofSize: 15)
        label.textColor = .labelColor
        label.maximumNumberOfLines = 3
        label.lineBreakMode = .byTruncatingHead
        label.translatesAutoresizingMaskIntoConstraints = false
        backdrop.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor, constant: -16),
            label.topAnchor.constraint(equalTo: backdrop.topAnchor, constant: 12),
            label.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor, constant: -12),
            label.widthAnchor.constraint(equalToConstant: 488),
        ])
        panel.contentView = backdrop
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.panel.isVisible else { return }
                UserDefaults.standard.set(NSStringFromPoint(self.panel.frame.origin), forKey: "bubble.origin")
            }
        }
    }

    func show(_ text: String, dim: Bool = false) {
        label.stringValue = text
        label.textColor = dim ? .secondaryLabelColor : .labelColor
        let size = panel.contentView?.fittingSize ?? NSSize(width: 520, height: 48)
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let saved = UserDefaults.standard.string(forKey: "bubble.origin").map(NSPointFromString)
        if let saved, NSScreen.screens.contains(where: { $0.visibleFrame.contains(saved) }) {
            panel.setFrame(NSRect(origin: saved, size: size), display: true)
        } else if let area = screen?.visibleFrame {
            panel.setFrame(NSRect(x: area.midX - size.width / 2, y: area.minY + 72, width: size.width, height: size.height), display: true)
        }
        panel.orderFrontRegardless()
    }

    func hide() { panel.orderOut(nil) }
}
