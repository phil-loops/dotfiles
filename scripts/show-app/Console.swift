import AppKit
import CanopyCore
import WebKit

/// A page served on this machine, in a web view. Showing it starts its server first when nothing answers; the server outlives Show.
class LocalPageController: NSViewController, WKNavigationDelegate {
    let name: String
    /// Answers when the server is up; `page` is what the web view loads.
    let health: URL
    let page: URL
    /// A zsh line that starts the server; `arguments` fill `$0…`.
    let startLine: String
    let arguments: [String]
    let web = WKWebView(frame: .zero, configuration: {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        return configuration
    }())
    let note = NSTextField(labelWithString: "")
    private var starting = false
    private var loaded = false

    init(name: String, health: URL, page: URL, startLine: String, arguments: [String] = []) {
        self.name = name
        self.health = health
        self.page = page
        self.startLine = startLine
        self.arguments = arguments
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("unused") }

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

    /// Loads the page, starting its server first when nothing answers. Safe to call on every visit.
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
            self.say("Starting \(self.name)…")
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
        web.load(URLRequest(url: page))
    }

    private func say(_ text: String) {
        note.stringValue = text
        note.isHidden = text.isEmpty
        web.isHidden = !text.isEmpty
    }

    private func answers(_ done: @escaping (Bool) -> Void) {
        var request = URLRequest(url: health)
        request.timeoutInterval = 1
        URLSession.shared.dataTask(with: request) { _, response, _ in
            let up = (response as? HTTPURLResponse).map { $0.statusCode < 500 } ?? false
            DispatchQueue.main.async { done(up) }
        }.resume()
    }

    private func launch() {
        let process = Zsh.process(startLine, arguments)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            starting = false
            say("Couldn't start \(name): \(error.localizedDescription)")
        }
    }

    private func waitForServer(tries: Int) {
        guard starting else { return }
        guard tries > 0 else {
            starting = false
            say("\(name) didn't come up. Run `\(startLine.replacingOccurrences(of: "exec ", with: ""))` in a terminal to see why, then ⌘R.")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.answers { up in up ? self?.load() : self?.waitForServer(tries: tries - 1) }
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loaded = false
        say("\(name) stopped answering. ⌘R starts it again.")
    }
}

/// The loops-postman console (:7070), against the repo's local spec so unreleased endpoints show too. It is what the Bench
/// workspace shows while no bench is open.
final class ConsoleController: LocalPageController {
    init() {
        let address = URL(string: "http://127.0.0.1:7070")!
        super.init(name: "the API console", health: address, page: address, startLine: "exec loops-postman serve --spec \"$0\" --no-open",
                   arguments: [("~/coding/loops/public/openapi.json" as NSString).expandingTildeInPath])
    }

    required init?(coder: NSCoder) { fatalError("unused") }
}

/// What Show reads of a bench document (`"mode": "bench"`): its title and the forest it belongs to. The scenario itself, the
/// `bench` object's env, groups and steps, is the `bench` runner's to read (`scripts/bench`).
struct BenchHead: Decodable {
    struct Scenario: Decodable {
        let ticket: String?
        let repo: String?
        let project: String?
    }
    let title: String
    let replyTo: String?
    let bench: Scenario

    /// The forest the bench belongs to, as a canopy address.
    var canopyRoute: String? {
        guard let repo = bench.repo, let project = bench.project else { return nil }
        return "/v2/p/\(repo)/\(project)"
    }
}

func loadBenchHead(_ path: String) -> BenchHead? {
    try? JSONDecoder().decode(BenchHead.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
}

/// One bench document's page, served by `bench serve` (:7240), which runs any scenario by its file.
final class BenchPageController: LocalPageController {
    static let server = URL(string: "http://127.0.0.1:7240/")!
    let head: BenchHead

    init(path: String, head: BenchHead) {
        self.head = head
        var page = URLComponents(url: Self.server.appendingPathComponent("b"), resolvingAgainstBaseURL: false)!
        page.queryItems = [URLQueryItem(name: "file", value: path)]
        super.init(name: "the bench runner", health: Self.server, page: page.url!, startLine: "exec bench serve")
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    static let keys: Void = KeyTable.register([
        KeyBinding(id: "bench.canopy", menu: "Workspace", title: "Open Bench's Forest in Canopy", key: "O", modifiers: [.command, .shift], workspaces: [.api]) {
            $0.workspaces[.api]?.openBenchForest()
        },
        KeyBinding(id: "bench.console", menu: "Workspace", title: "Close Bench, Show API Console", key: "B", modifiers: [.command, .shift], workspaces: [.api]) {
            $0.workspaces[.api]?.showConsole()
        },
    ])
}
