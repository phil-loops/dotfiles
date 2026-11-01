import Foundation

/// How canopy and Show start every outside tool: `zsh -c script $0 $@`. Plain `-c` reads only
/// ~/.zshenv, which owns the PATH for shells that aren't interactive (volta's node, homebrew,
/// ~/.local/bin, the dotfiles scripts). Never `-l`: .zprofile then loads nvm's node 18 over volta's,
/// and node tools (tsc, oxlint, loops-postman) fail to start.
public enum Zsh {
    public static let path = "/bin/zsh"

    public static func arguments(_ script: String, _ args: [String] = []) -> [String] { ["-c", script] + args }

    public static func process(_ script: String, _ args: [String] = []) -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = arguments(script, args)
        return p
    }
}
