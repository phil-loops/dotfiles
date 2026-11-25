import AppKit
import Foundation

let pattern = try! NSRegularExpression(
  pattern: #"https://admin\.your-tailnet\.ts\.net(?!/admin(?:[/?#\s]|$))"#,
  options: [.anchorsMatchLines]
)

func shareable(_ text: String) -> String {
  let range = NSRange(text.startIndex..., in: text)
  return pattern.stringByReplacingMatches(in: text, range: range, withTemplate: "https://app.loops.so")
}

if CommandLine.arguments.count > 1 {
  print(shareable(CommandLine.arguments[1]))
  exit(0)
}

let board = NSPasteboard.general
var seen = board.changeCount
Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { _ in
  guard board.changeCount != seen else { return }
  seen = board.changeCount
  guard let text = board.string(forType: .string) else { return }
  let rewritten = shareable(text)
  guard rewritten != text else { return }
  board.clearContents()
  board.setString(rewritten, forType: .string)
  seen = board.changeCount
}
RunLoop.main.run()
