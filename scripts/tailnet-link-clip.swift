import AppKit
import Foundation

let host = "admin.your-tailnet.ts.net"
let outsideAdmin = try! NSRegularExpression(pattern: #"https://admin\.your-tailnet\.ts\.net(?!/admin(?![\w-]))"#)
let textTypes: Set<NSPasteboard.PasteboardType> = [.string, .html, .rtf, .URL]
let leaveAlone: Set<String> = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType"]
let keepWindow: TimeInterval = 2

func shareable(_ text: String) -> String {
  outsideAdmin.stringByReplacingMatches(
    in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "https://app.loops.so")
}

if CommandLine.arguments.count == 2 {
  print(shareable(CommandLine.arguments[1]))
  exit(0)
}

let board = NSPasteboard.general
var seen = board.changeCount
var lastRewrite: (original: String, at: Date)?

func rewrittenItems() -> [NSPasteboardItem]? {
  guard let items = board.pasteboardItems, !items.isEmpty else { return nil }
  if items.contains(where: { $0.types.contains { leaveAlone.contains($0.rawValue) } }) { return nil }
  var changed = false
  let copies = items.map { item -> NSPasteboardItem in
    let copy = NSPasteboardItem()
    for type in item.types {
      guard let data = item.data(forType: type) else { continue }
      if textTypes.contains(type), let text = String(data: data, encoding: .utf8) {
        let new = shareable(text)
        if new != text {
          changed = true
          copy.setData(Data(new.utf8), forType: type)
          continue
        }
      }
      copy.setData(data, forType: type)
    }
    return copy
  }
  return changed ? copies : nil
}

let poll = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
  guard board.changeCount != seen else { return }
  seen = board.changeCount
  let text = board.string(forType: .string) ?? ""
  let html = board.string(forType: .html) ?? ""
  guard text.contains(host) || html.contains(host) else { return }
  if let last = lastRewrite, last.original == text, Date().timeIntervalSince(last.at) < keepWindow {
    lastRewrite = nil
    return
  }
  guard let items = rewrittenItems() else { return }
  board.clearContents()
  board.writeObjects(items)
  seen = board.changeCount
  lastRewrite = (text, Date())
}
poll.tolerance = 0.05
RunLoop.main.run()
