import AppKit
import CanopyCore

/// `Ctrl-a v` in tmux opens `canopy://dictate?pane=<id>` in the background: Show records, and ⌃⌥↩ (or the key again) drops the
/// transcript as a draft into the Claude session that pane hosted at the press, wherever focus has gone since. Delivery is
/// `claude-say --draft` by session id, so a pane whose session has changed refuses instead of taking someone else's words.
@MainActor
final class PaneDictation {
    struct Session: Decodable, Equatable {
        let session_id: String
        let pane: String
        let topic: String
    }

    private let voice = LearnVoice()

    /// The tmux pane a dictate link names ("%12"), or nil for any other link.
    nonisolated static func pane(of link: URL) -> String? {
        guard link.scheme == "canopy", link.host == "dictate",
              let id = URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems?
                  .first(where: { $0.name == "pane" })?.value.flatMap({ Int($0) }) else { return nil }
        return "%\(id)"
    }

    /// The Claude session `claude-say --json` places in `pane`.
    nonisolated static func session(in pane: String, listing: Data) -> Session? {
        (try? JSONDecoder().decode([Session].self, from: listing))?.first { $0.pane == pane }
    }

    func toggle(pane: String) {
        if voice.active {
            voice.toggle { _ in }
            return
        }
        DispatchQueue.global().async {
            let listing = Self.run([claudeSayPath, "--json"])
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard listing.status == 0, let session = Self.session(in: pane, listing: listing.out) else {
                    Self.tell(pane, "No Claude session in this pane to dictate to")
                    return
                }
                self.start(for: session)
            }
        }
    }

    private func start(for session: Session) {
        voice.listening = "Dictating to \(session.topic.isEmpty ? session.pane : session.topic)"
        voice.onError = { Self.tell(session.pane, $0) }
        Self.tell(session.pane, "Listening, ⌃⌥↩ to finish")
        voice.toggle { text in
            DispatchQueue.global().async {
                let sent = Self.run([claudeSayPath, session.session_id, "--draft", "--unsigned", text])
                guard sent.status != 0 else { return }
                let reason = String(data: sent.err, encoding: .utf8)?
                    .split(separator: "\n").first.map(String.init) ?? "claude-say failed"
                DispatchQueue.main.async {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    Self.tell(session.pane, "Dictation not delivered (\(reason)); it's on the clipboard")
                }
            }
        }
    }

    /// A message on the pane's tmux status line, so Show never has to come forward.
    private static func tell(_ pane: String, _ message: String) {
        DispatchQueue.global().async {
            if run(["tmux", "display-message", "-d", "6000", "-t", pane, "Show: " + message]).status != 0 {
                DispatchQueue.main.async { NSSound.beep() }
            }
        }
    }

    nonisolated private static func run(_ command: [String]) -> (status: Int32, out: Data, err: Data) {
        let process = Zsh.process("exec \"$0\" \"$@\"", command)
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do { try process.run() } catch { return (-1, Data(), Data(error.localizedDescription.utf8)) }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errors = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, data, errors)
    }
}
