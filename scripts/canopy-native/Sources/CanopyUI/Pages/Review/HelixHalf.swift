import AppKit
import CanopyCore
import SwiftTerm
import SwiftUI

/// Helix in the diff (`i` over the new half, `o` over the whole of it): the branch's diff-view
/// checkout, whose files are the tip and whose gutter marks the branch's changes, opened at the
/// cursor's line and name. `:w` saves there as Helix always does; quitting commits what changed.
public struct HelixOpen: Equatable {
    public var path: String
    public var line: Int
    public var col: Int
    /// the checkout, once the server has made it
    public var dir: String?
    /// the tip Helix opened at; the commit is refused if the branch moved since
    public var sha: String
    /// over the whole diff (`o`), not just its new half (`i`)
    public var whole = false
    /// opened from the open file: quitting puts that pane back where Helix left off
    public var fromSide = false
    public let session = UUID()
    let source: BranchSource
    let reader: ReaderContext

    public static func == (lhs: HelixOpen, rhs: HelixOpen) -> Bool {
        lhs.session == rhs.session && lhs.path == rhs.path && lhs.line == rhs.line && lhs.col == rhs.col &&
            lhs.dir == rhs.dir && lhs.sha == rhs.sha && lhs.whole == rhs.whole && lhs.fromSide == rhs.fromSide && lhs.source == rhs.source
    }
}

private struct HelixWhere: Decodable { var ok: Bool; var dir: String?; var sha: String?; var err: String? }

extension ReviewPageState {
    func openHelix(_ app: AppModel, branch: String, path: String, line: Int, col: Int, whole: Bool = false, fromSide: Bool = false) {
        guard helix == nil, diffCurrent, !scoped, integration == nil, let t = target, t.name == branch,
              let source = BranchSource.current(app, t.id), HelixLanding.fullObject(source.tip) else { return }
        let reader = ReaderContext(app)
        let open = HelixOpen(path: path, line: line, col: col, sha: source.tip, whole: whole, fromSide: fromSide, source: source, reader: reader)
        helixTask?.cancel()
        helixSession = open.session
        pendingHelixReturn = nil
        helixAt = nil
        helix = open
        app.runner.say("checking \(source.repo)/\(branch) out for Helix…")
        helixTask = Task { @MainActor in
            @MainActor func current() -> Bool {
                helix?.session == open.session && !Task.isCancelled && reader.isCurrent(app) && diffCurrent && BranchSource.current(app, source.id) == source
            }
            defer { if helix?.session == open.session && helix?.dir == nil { helix = nil } }
            guard current() else { return }
            let body = ["branch": source.name, "op": "where"]
            let answer = await app.transport.ask(app.transport.atRepo(source.repo, "/review-helix"), body, as: HelixWhere.self)
            guard current() else { return }
            guard let answer, answer.ok, answer.sha == source.tip, let dir = answer.dir, dir.hasPrefix("/") else {
                return app.runner.say(answer?.err ?? "couldn't prepare Helix at the shown commit · try again")
            }
            helix?.dir = dir
            app.runner.say("Helix on \(source.repo)/\(branch) · :w saves · quitting commits it")
        }
    }

    @discardableResult func cancelHelixPreparation() -> Bool {
        guard let open = helix, open.dir == nil else { return false }
        helixTask?.cancel()
        helixTask = nil
        helix = nil
        helixAt = nil
        return true
    }

    func moveHelix(session: UUID, path: String, line: Int) {
        guard helix?.session == session, line > 0, !path.hasPrefix("/"),
              !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return }
        helixAt = (path, line)
    }

    /// Resolve origin from an explicitly targeted checkout at the observed head.
    func githubPage(_ app: AppModel, source: BranchSource) async -> String? {
        func current() -> Bool { !Task.isCancelled && BranchSource.current(app, source.id) == source }
        guard current() else { return nil }
        if let stub = githubWeb {
            let web = await stub(app)
            return current() ? web : nil
        }
        let body = ["branch": source.name, "op": "where"]
        let answer = await app.transport.ask(app.transport.atRepo(source.repo, "/review-helix"), body, as: HelixWhere.self)
        guard current(), let answer, answer.ok, answer.sha == source.tip, let dir = answer.dir, !dir.isEmpty else { return nil }
        let web = await githubOrigin(dir)
        return current() ? web : nil
    }

    /// origin's URL as a github.com page: `git@github.com:o/r.git` and `https://github.com/o/r.git` → `https://github.com/o/r`.
    nonisolated static func originWeb(_ dir: String) async -> String? {
        await withCheckedContinuation { (k: CheckedContinuation<String?, Never>) in
            let p = Zsh.process("exec git -C \"$0\" remote get-url origin", [dir])
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            p.terminationHandler = { _ in
                let raw = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                k.resume(returning: githubPage(remote: raw))
            }
            do { try p.run() } catch { k.resume(returning: nil) }
        }
    }

    nonisolated static func githubPage(remote raw: String) -> String? {
        var u = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if u.hasSuffix(".git") { u.removeLast(4) }
        if u.hasPrefix("git@github.com:") { u = "https://github.com/" + u.dropFirst("git@github.com:".count) }
        if u.hasPrefix("ssh://git@github.com/") { u = "https://github.com/" + u.dropFirst("ssh://git@github.com/".count) }
        return u.hasPrefix("https://github.com/") ? u : nil
    }

    func finishHelix(_ app: AppModel, session: UUID, exitCode: Int32?) {
        guard let open = helix, open.session == session else { return }
        guard exitCode == 0 else {
            helix = nil
            helixAt = nil
            if id == open.source.id { app.runner.say("Helix stopped · edits are saved in \(open.dir ?? "its checkout")") }
            return
        }
        landHelix(app, session: session)
    }

    /// Quit consumes only its own editor session; the registered write keeps that session's owner.
    func landHelix(_ app: AppModel, session: UUID? = nil) {
        guard let open = helix, session == nil || session == open.session, let dir = open.dir else { return }
        helix = nil
        let at = helixAt ?? (open.path, open.line)
        helixAt = nil
        var reader: ReaderContext?
        if id == open.source.id, tip == open.source.tip, diffCurrent, !scoped, open.reader.isCurrent(app) {
            let destination: HelixReturn.Destination
            let key = stopNear(path: at.path, line: at.line)
            if open.fromSide, key == nil, let window = code, let previous = window.doc {
                if previous.repo == open.source.repo, previous.sha == open.source.tip, previous.path == at.path, window.text != nil {
                    let loc = Loc(repo: open.source.repo, sha: open.source.tip, path: at.path, line: at.line)
                    show(loc, in: window)
                    destination = .file(window, loc)
                } else { destination = .file(window, previous) }
            } else {
                destination = .diff
                if let key { setCursor(key) }
                app.focus(pane: reviewDiffPane)
            }
            reader = ReaderContext(app)
            pendingHelixReturn = HelixReturn(app, open: open, path: at.path, line: at.line, destination: destination)
        }
        guard app.store.epoch == open.source.epoch else {
            if pendingHelixReturn?.session == open.session { pendingHelixReturn = nil }
            if reader?.isCurrent(app) == true { app.runner.say("the server changed · edits are saved in \(dir)") }
            return
        }
        let landing = HelixLanding(open: open, dir: dir, reader: reader)
        helixLandingPermits.insert(open.session)
        app.runner.dispatch("review.helix.land", via: .key, target: open.source.id, arg: landing)
    }

}

/// Helix's position from its status line ("NOR   pages/x.tsx [+]   1 sel  12:4"): the file and the line.
func helixStatus(_ line: String) -> (path: String, line: Int)? {
    let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
    guard parts.count >= 3, ["NOR", "INS", "SEL"].contains(parts[0]),
          let pos = parts.last, let colon = pos.firstIndex(of: ":"), let n = Int(pos[..<colon]), Int(pos[pos.index(after: colon)...]) != nil
    else { return nil }
    return (parts[1], n)
}

/// A terminal that reads Helix's status line as the screen updates, so quitting knows where the cursor was.
final class HelixTerminal: LocalProcessTerminalView {
    var onPosition: ((String, Int) -> Void)?

    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
        let term = getTerminal()
        for row in stride(from: term.rows - 1, through: max(0, term.rows - 3), by: -1) {
            if let text = term.getLine(row: row)?.translateToString(trimRight: true), let at = helixStatus(text) {
                onPosition?(at.path, at.line)
                return
            }
        }
    }
}

/// The terminal Helix runs in, over the new half or the whole page. It takes the keyboard while it's open.
struct HelixHalf: NSViewRepresentable {
    let open: HelixOpen
    let dir: String
    let colors: CanvasColors
    var moved: (String, Int) -> Void = { _, _ in }
    let quit: (Int32?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(quit: quit) }

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        // starts at a real size, so Helix lays out once before SwiftUI sizes it
        let t = HelixTerminal(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        t.onPosition = moved
        t.processDelegate = context.coordinator
        for v in t.subviews where v is NSScroller { v.isHidden = true }   // Helix scrolls itself
        t.font = .monospacedSystemFont(ofSize: DocFont.size, weight: .regular)
        t.nativeBackgroundColor = colors.bg
        t.nativeForegroundColor = colors.ink
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        t.startProcess(executable: Zsh.path, args: Zsh.arguments("exec hx \"$0\"", ["\(open.path):\(open.line):\(open.col)"]),
                       environment: env.map { "\($0)=\($1)" }, currentDirectory: dir)
        DispatchQueue.main.async { t.window?.makeFirstResponder(t) }
        return t
    }

    func updateNSView(_ t: LocalProcessTerminalView, context: Context) {
        context.coordinator.quit = quit
    }

    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        var quit: (Int32?) -> Void
        init(quit: @escaping (Int32?) -> Void) { self.quit = quit }

        func processTerminated(source: TerminalView, exitCode: Int32?) {
            DispatchQueue.main.async { [quit] in quit(exitCode) }
        }
        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    }
}
