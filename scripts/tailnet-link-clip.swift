import AppKit
import Foundation

let lone = try! NSRegularExpression(pattern: #"^https://admin\.your-tailnet\.ts\.net(?!/admin(?![\w-]))([/?#]\S*)?$"#)
let textTypes: Set<NSPasteboard.PasteboardType> = [.string, .html, .rtf, .URL]
let leaveAlone: Set<String> = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType"]
let keepWindow: TimeInterval = 2

/// The app.loops.so form of `text` when it is exactly one tailnet URL outside /admin, else nil.
func shareable(_ text: String) -> String? {
  let url = text.trimmingCharacters(in: .whitespacesAndNewlines)
  guard lone.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil else { return nil }
  return "https://app.loops.so" + url.dropFirst("https://admin.your-tailnet.ts.net".count)
}

if CommandLine.arguments.count == 2 {
  print(shareable(CommandLine.arguments[1]) ?? CommandLine.arguments[1])
  exit(0)
}

let board = NSPasteboard.general
var seen = board.changeCount
var lastRewrite: (original: String, at: Date)?

func rewrittenItems(from original: String, to shared: String) -> [NSPasteboardItem]? {
  guard let items = board.pasteboardItems, !items.isEmpty else { return nil }
  if items.contains(where: { $0.types.contains { leaveAlone.contains($0.rawValue) } }) { return nil }
  let escapedOriginal = original.replacingOccurrences(of: "&", with: "&amp;")
  let escapedShared = shared.replacingOccurrences(of: "&", with: "&amp;")
  return items.map { item -> NSPasteboardItem in
    let copy = NSPasteboardItem()
    for type in item.types {
      guard let data = item.data(forType: type) else { continue }
      if textTypes.contains(type), let text = String(data: data, encoding: .utf8) {
        let new = text
          .replacingOccurrences(of: original, with: shared)
          .replacingOccurrences(of: escapedOriginal, with: escapedShared)
        copy.setData(Data(new.utf8), forType: type)
      } else {
        copy.setData(data, forType: type)
      }
    }
    return copy
  }
}

let poll = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
  guard board.changeCount != seen else { return }
  seen = board.changeCount
  guard let text = board.string(forType: .string), let shared = shareable(text) else { return }
  if let last = lastRewrite, last.original == text, Date().timeIntervalSince(last.at) < keepWindow {
    lastRewrite = nil
    return
  }
  let original = text.trimmingCharacters(in: .whitespacesAndNewlines)
  guard let items = rewrittenItems(from: original, to: shared) else { return }
  board.clearContents()
  board.writeObjects(items)
  seen = board.changeCount
  lastRewrite = (text, Date())
}
poll.tolerance = 0.05
RunLoop.main.run()
