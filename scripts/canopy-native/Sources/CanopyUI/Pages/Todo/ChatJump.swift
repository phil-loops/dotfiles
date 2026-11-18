import CanopyCore
import Foundation

/// Brings a Claude Code chat's tmux pane forward through `claude-jump`, the one tool Show's decks use too.
enum ChatJump {
    static var path: String {
        ProcessInfo.processInfo.environment["SHOW_CLAUDE_JUMP"] ?? ("~/.dotfiles/scripts/claude-jump" as NSString).expandingTildeInPath
    }

    /// Runs it for the chat's full session id; returns what went wrong, or nil.
    static func run(_ session: String) -> String? {
        let process = Zsh.process("exec \"$0\" \"$@\"", [path, session])
        let errors = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return error.localizedDescription
        }
        guard process.terminationStatus != 0 else { return nil }
        return String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
