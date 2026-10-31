import AppKit
import CanopyUI

/// The Canopy workspace: the forest viewer's pages, canopy's own keys while it's in front. Opening it
/// starts the repo's viewer server when nothing answers, as the menu bar's launcher does.
final class CanopyHost: NSViewController {
    static let repo = "~/coding/loops"
    var isActive: () -> Bool = { false }
    private var embed: CanopyEmbed?
    private var pendingRoute: String?
    private var starting = false
    private let note = NSTextField(labelWithString: "")

    override func loadView() {
        let container = PageBackdrop()
        note.font = .systemFont(ofSize: 13)
        note.textColor = .secondaryLabelColor
        note.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(note)
        NSLayoutConstraint.activate([
            note.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            note.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        view = container
    }

    /// Brings canopy up on its first visit, and goes to `route` (a /v2/… path) once it's there.
    func start(route: String? = nil) {
        _ = view
        if let route { pendingRoute = route }
        if let embed {
            if let r = pendingRoute { embed.navigate(r); pendingRoute = nil }
            view.window?.makeFirstResponder(embed.view)
            return
        }
        guard !starting else { return }
        starting = true
        probe { [weak self] up in
            guard let self else { return }
            if up { return self.attach() }
            self.say("Starting the forest viewer…")
            let serve = Process()
            serve.executableURL = URL(fileURLWithPath: "/bin/zsh")
            serve.arguments = ["-lc", "cd \(Self.repo) && exec \"$HOME/.dotfiles/scripts/stack-review-serve\" --no-open"]
            serve.standardOutput = FileHandle.nullDevice
            serve.standardError = FileHandle.nullDevice
            try? serve.run()
            self.wait(tries: 120)
        }
    }

    private func wait(tries: Int) {
        guard tries > 0 else {
            starting = false
            return say("The forest viewer didn't come up. Run `stack web` in a terminal to see why, then ⌘R.")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.probe { up in up ? self?.attach() : self?.wait(tries: tries - 1) }
        }
    }

    private func probe(_ done: @escaping (Bool) -> Void) {
        DispatchQueue.global().async {
            var config = AppConfig()
            config.repo = Self.repo
            let up = config.resolvedPort().map(CanopyEmbed.answers) ?? false
            DispatchQueue.main.async { done(up) }
        }
    }

    private func attach() {
        starting = false
        guard let embed = CanopyEmbed(repo: Self.repo, route: pendingRoute, isActive: { [weak self] in self?.isActive() ?? false }) else {
            return say("The forest viewer stopped answering. ⌘R tries again.")
        }
        pendingRoute = nil
        self.embed = embed
        say("")
        pinned(embed.view, in: view)
        view.window?.makeFirstResponder(embed.view)
    }

    private func say(_ text: String) {
        note.stringValue = text
        note.isHidden = text.isEmpty
    }
}
