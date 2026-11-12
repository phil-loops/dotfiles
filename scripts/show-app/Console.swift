import AppKit
import CanopyCore
import WebKit

/// A page the API workspace shows: the loops-postman console, or a bench registered as `<decks>/benches/<id>.json`
/// (`{"title", "url", "start", "repo"?, "project"?, "branches"?}`). A bench is a local tool page tied to a forest: Show starts
/// its server with `start` when nothing answers at `url`, and ⌘⇧O opens its project in canopy.
struct Bench: Equatable {
    let id: String
    let title: String
    let address: URL
    /// A zsh line that starts the page's server; `arguments` fill `$0…`.
    let start: String
    var arguments: [String] = []
    var repo: String? = nil
    var project: String? = nil
    var branches: [String] = []

    static let directory = (decksDirectory as NSString).appendingPathComponent("benches")
    static let console = Bench(
        id: "console", title: "API console", address: URL(string: "http://127.0.0.1:7070")!,
        start: "exec loops-postman serve --spec \"$0\" --no-open",
        arguments: [("~/coding/loops/public/openapi.json" as NSString).expandingTildeInPath])

    /// The forest this bench belongs to, as a canopy address.
    var canopyRoute: String? {
        guard let repo, let project else { return nil }
        return "/v2/p/\(repo)/\(project)"
    }

    private struct File: Decodable {
        let title: String
        let url: String
        let start: String
        let repo: String?
        let project: String?
        let branches: [String]?
    }

    /// The registered benches, by title. A file that doesn't parse is left out.
    static func registered(in directory: String = Bench.directory) -> [Bench] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        return names.filter { $0.hasSuffix(".json") }.compactMap { name -> Bench? in
            let path = (directory as NSString).appendingPathComponent(name)
            guard let data = FileManager.default.contents(atPath: path),
                  let file = try? JSONDecoder().decode(File.self, from: data),
                  let address = URL(string: file.url) else { return nil }
            return Bench(id: String(name.dropLast(".json".count)), title: file.title, address: address, start: file.start,
                         repo: file.repo, project: file.project, branches: file.branches ?? [])
        }.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    static func titled(_ id: String) -> String {
        ([console] + registered()).first { $0.id == id }?.title ?? id
    }
}

/// The API workspace: the loops-postman console and the registered benches, each in its own web view, with a switcher on top
/// when there is more than one. Showing a page starts its server when it isn't answering; the servers outlive Show.
final class ConsoleController: NSViewController, WKNavigationDelegate {
    private(set) var benches: [Bench] = [.console]
    private(set) var current = UserDefaults.standard.string(forKey: "apiBench") ?? Bench.console.id
    private var webs: [String: WKWebView] = [:]
    private var loaded: Set<String> = []
    private var starting: Set<String> = []
    private let bar = NSStackView()
    private let switcher = NSSegmentedControl()
    private let forest = NSButton(title: "", target: nil, action: nil)
    private let pages = NSView()
    let note = NSTextField(labelWithString: "")

    static let keys: Void = KeyTable.register([
        KeyBinding(id: "bench.next", menu: "Workspace", title: "Next Bench", key: "B", modifiers: [.command, .shift], workspaces: [.api]) {
            $0.workspaces[.api]?.console?.showNext()
        },
        KeyBinding(id: "bench.canopy", menu: "Workspace", title: "Open Bench's Forest in Canopy", key: "O", modifiers: [.command, .shift], workspaces: [.api]) {
            $0.workspaces[.api]?.console?.openForest()
        },
    ])

    var bench: Bench { benches.first { $0.id == current } ?? .console }

    override func loadView() {
        _ = Self.keys
        let container = PageBackdrop()
        switcher.segmentStyle = .automatic
        switcher.trackingMode = .selectOne
        switcher.target = self
        switcher.action = #selector(picked)
        forest.bezelStyle = .inline
        forest.target = self
        forest.action = #selector(openForest)
        bar.orientation = .horizontal
        bar.spacing = 12
        bar.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
        bar.addArrangedSubview(switcher)
        bar.addArrangedSubview(NSView())
        bar.addArrangedSubview(forest)
        let column = NSStackView(views: [bar, pages])
        column.orientation = .vertical
        column.spacing = 0
        column.alignment = .leading
        pinned(column, in: container)
        NSLayoutConstraint.activate([
            bar.widthAnchor.constraint(equalTo: column.widthAnchor),
            pages.widthAnchor.constraint(equalTo: column.widthAnchor),
        ])
        note.font = .systemFont(ofSize: 13)
        note.textColor = .secondaryLabelColor
        note.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(note)
        NSLayoutConstraint.activate([
            note.centerXAnchor.constraint(equalTo: pages.centerXAnchor),
            note.centerYAnchor.constraint(equalTo: pages.centerYAnchor),
        ])
        view = container
        refresh()
    }

    /// Re-reads the registry and redraws the switcher; a bench that was removed falls back to the console.
    func refresh() {
        benches = [.console] + Bench.registered()
        if !benches.contains(where: { $0.id == current }) { current = Bench.console.id }
        switcher.segmentCount = benches.count
        for (index, bench) in benches.enumerated() {
            switcher.setLabel(bench.title, forSegment: index)
            switcher.setWidth(0, forSegment: index)
        }
        switcher.selectedSegment = benches.firstIndex { $0.id == current } ?? 0
        forest.title = bench.project.map { "\($0) in canopy" } ?? ""
        forest.isHidden = bench.canopyRoute == nil
        bar.isHidden = benches.count < 2
        for (id, web) in webs { web.isHidden = id != current || !loaded.contains(id) }
    }

    /// Puts bench `id` in front and starts it. An unknown id leaves the current page and says so.
    func show(_ id: String) {
        _ = view
        refresh()
        guard benches.contains(where: { $0.id == id }) else {
            say("No bench named “\(id)” in \(Bench.directory)")
            return
        }
        current = id
        UserDefaults.standard.set(id, forKey: "apiBench")
        refresh()
        if snapshotPath == nil && selfTest == nil { start() }
    }

    func showNext() {
        refresh()
        guard benches.count > 1, let index = benches.firstIndex(where: { $0.id == current }) else { return }
        show(benches[(index + 1) % benches.count].id)
    }

    @objc private func picked() {
        guard benches.indices.contains(switcher.selectedSegment) else { return }
        show(benches[switcher.selectedSegment].id)
    }

    /// ⌘⇧O: the current bench's forest in the Canopy workspace.
    @objc func openForest() {
        guard let route = bench.canopyRoute else {
            say(loaded.contains(current) ? "" : "\(bench.title) names no forest")
            return
        }
        (NSApp.delegate as? AppDelegate)?.open(.canopy(route))
    }

    /// Loads the current page, starting its server first when nothing answers. Safe to call on every visit.
    func start() {
        _ = view
        refresh()
        let bench = self.bench
        guard !loaded.contains(bench.id) else {
            say("")
            return
        }
        guard !starting.contains(bench.id) else { return }
        starting.insert(bench.id)
        answers(bench) { [weak self] up in
            guard let self else { return }
            if up {
                self.load(bench)
                return
            }
            self.say("Starting \(bench.title)…", for: bench)
            self.launch(bench)
            self.waitForServer(bench, tries: 75)
        }
    }

    func reload() {
        if loaded.contains(current) {
            webs[current]?.reload()
        } else {
            start()
        }
    }

    private func web(for bench: Bench) -> WKWebView {
        if let existing = webs[bench.id] { return existing }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.navigationDelegate = self
        web.setValue(false, forKey: "drawsBackground")
        web.isHidden = true
        pinned(web, in: pages)
        webs[bench.id] = web
        return web
    }

    private func load(_ bench: Bench) {
        starting.remove(bench.id)
        loaded.insert(bench.id)
        web(for: bench).load(URLRequest(url: bench.address))
        say("", for: bench)
        refresh()
    }

    /// The centred line over the page area; a line about a bench that isn't in front is dropped.
    private func say(_ text: String, for bench: Bench? = nil) {
        if let bench, bench.id != current { return }
        note.stringValue = text
        note.isHidden = text.isEmpty
        webs[current]?.isHidden = !text.isEmpty || !loaded.contains(current)
    }

    private func answers(_ bench: Bench, _ done: @escaping (Bool) -> Void) {
        var request = URLRequest(url: bench.address)
        request.timeoutInterval = 1
        URLSession.shared.dataTask(with: request) { _, response, _ in
            let up = (response as? HTTPURLResponse).map { $0.statusCode < 500 } ?? false
            DispatchQueue.main.async { done(up) }
        }.resume()
    }

    private func launch(_ bench: Bench) {
        let process = Zsh.process(bench.start, bench.arguments)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            starting.remove(bench.id)
            say("Couldn't start \(bench.title): \(error.localizedDescription)", for: bench)
        }
    }

    private func waitForServer(_ bench: Bench, tries: Int) {
        guard starting.contains(bench.id) else { return }
        guard tries > 0 else {
            starting.remove(bench.id)
            say("\(bench.title) didn't come up. Run `\(bench.start.replacingOccurrences(of: "exec ", with: ""))` in a terminal to see why, then ⌘R.", for: bench)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.answers(bench) { up in up ? self?.load(bench) : self?.waitForServer(bench, tries: tries - 1) }
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard let id = webs.first(where: { $0.value === webView })?.key else { return }
        loaded.remove(id)
        if id == current { say("\(bench.title) stopped answering. ⌘R starts it again.") }
    }
}
