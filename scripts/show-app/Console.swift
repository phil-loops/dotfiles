import AppKit
import WebKit

/// The API workspace: the loops-postman console (:7070) in a web view. Opening the workspace starts the console when it isn't
/// answering, against the repo's local spec so unreleased endpoints show too; the server outlives Show, like the menu-bar launcher's.
final class ConsoleController: NSViewController, WKNavigationDelegate {
    static let address = URL(string: "http://127.0.0.1:7070")!
    static let spec = ("~/coding/loops/public/openapi.json" as NSString).expandingTildeInPath
    let web = WKWebView(frame: .zero, configuration: {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        return configuration
    }())
    let note = NSTextField(labelWithString: "")
    private var starting = false
    private var loaded = false

    override func loadView() {
        let container = PageBackdrop()
        web.navigationDelegate = self
        web.setValue(false, forKey: "drawsBackground")
        pinned(web, in: container)
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

    /// Loads the console, starting its server first when nothing answers on :7070. Safe to call on every visit.
    func start() {
        _ = view
        guard !loaded, !starting else { return }
        starting = true
        answers { [weak self] up in
            guard let self else { return }
            if up {
                self.load()
                return
            }
            self.say("Starting the API console…")
            self.launch()
            self.waitForServer(tries: 75)
        }
    }

    func reload() {
        if loaded {
            web.reload()
        } else {
            start()
        }
    }

    private func load() {
        starting = false
        loaded = true
        say("")
        web.load(URLRequest(url: Self.address))
    }

    private func say(_ text: String) {
        note.stringValue = text
        note.isHidden = text.isEmpty
        web.isHidden = !text.isEmpty
    }

    private func answers(_ done: @escaping (Bool) -> Void) {
        var request = URLRequest(url: Self.address)
        request.timeoutInterval = 1
        URLSession.shared.dataTask(with: request) { _, response, _ in
            let up = (response as? HTTPURLResponse).map { $0.statusCode < 500 } ?? false
            DispatchQueue.main.async { done(up) }
        }.resume()
    }

    private func launch() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "exec \"$HOME/.dotfiles/scripts/loops-postman\" serve --spec \"$0\" --no-open", Self.spec]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            starting = false
            say("Couldn't start loops-postman: \(error.localizedDescription)")
        }
    }

    private func waitForServer(tries: Int) {
        guard starting else { return }
        guard tries > 0 else {
            starting = false
            say("The API console didn't come up. Run `loops-postman serve` in a terminal to see why, then ⌘R.")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.answers { up in up ? self?.load() : self?.waitForServer(tries: tries - 1) }
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loaded = false
        say("The API console stopped answering. ⌘R starts it again.")
    }
}
