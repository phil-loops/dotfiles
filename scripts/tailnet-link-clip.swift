import AppKit
import Foundation

enum Audience: String { case external, `internal` }

let tailnet = "https://admin.your-tailnet.ts.net"
let app = "https://app.loops.so"
let toApp = try! NSRegularExpression(pattern: #"https://admin\.your-tailnet\.ts\.net(?!/admin(?:[/?#\s]|$))"#)
let toTailnet = try! NSRegularExpression(pattern: #"https://app\.loops\.so(?!/api(?:[/?#\s]|$))"#)
let modeFile = URL(fileURLWithPath: NSHomeDirectory() + "/.cache/tailnet-link-clip/audience")

func readAudience() -> Audience {
  let raw = (try? String(contentsOf: modeFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
  return Audience(rawValue: raw ?? "") ?? .external
}

func writeAudience(_ audience: Audience) {
  try? FileManager.default.createDirectory(at: modeFile.deletingLastPathComponent(), withIntermediateDirectories: true)
  try? audience.rawValue.write(to: modeFile, atomically: true, encoding: .utf8)
}

func shareable(_ text: String, for audience: Audience) -> String {
  let range = NSRange(text.startIndex..., in: text)
  switch audience {
  case .external: return toApp.stringByReplacingMatches(in: text, range: range, withTemplate: app)
  case .internal: return toTailnet.stringByReplacingMatches(in: text, range: range, withTemplate: tailnet)
  }
}

let args = Array(CommandLine.arguments.dropFirst())
if args.first == "audience" {
  if args.count > 1 {
    guard let audience = Audience(rawValue: args[1]) else {
      FileHandle.standardError.write("usage: tailnet-link-clip audience [external|internal]\n".data(using: .utf8)!)
      exit(2)
    }
    writeAudience(audience)
  }
  print(readAudience().rawValue)
  exit(0)
}
if args.count == 2, let audience = Audience(rawValue: args[0]) {
  print(shareable(args[1], for: audience))
  exit(0)
}

final class Watcher: NSObject {
  let board = NSPasteboard.general
  var seen = NSPasteboard.general.changeCount
  let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
  var shown: Audience?

  func start() {
    let menu = NSMenu()
    for audience in [Audience.external, .internal] {
      let entry = NSMenuItem(
        title: audience == .external ? "Customers — copy as app.loops.so" : "Team — copy as tailnet",
        action: #selector(choose(_:)), keyEquivalent: "")
      entry.target = self
      entry.representedObject = audience.rawValue
      menu.addItem(entry)
    }
    item.menu = menu
    render()
    Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in self?.tick() }
  }

  @objc func choose(_ sender: NSMenuItem) {
    writeAudience(Audience(rawValue: sender.representedObject as! String)!)
    render()
    seen = -1
  }

  func render() {
    let audience = readAudience()
    guard audience != shown else { return }
    shown = audience
    let symbol = audience == .external ? "globe" : "person.2"
    let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Copy links: \(audience.rawValue)")
    image?.isTemplate = true
    item.button?.image = image
    item.button?.imagePosition = .imageLeading
    item.button?.title = audience == .external ? "app.loops.so" : "tailnet"
    item.button?.toolTip = audience == .external ? "Copied links become app.loops.so" : "Copied links become tailnet"
    for entry in item.menu?.items ?? [] {
      entry.state = entry.representedObject as? String == audience.rawValue ? .on : .off
    }
  }

  func tick() {
    render()
    guard board.changeCount != seen else { return }
    seen = board.changeCount
    guard let text = board.string(forType: .string) else { return }
    let rewritten = shareable(text, for: readAudience())
    guard rewritten != text else { return }
    board.clearContents()
    board.setString(rewritten, forType: .string)
    seen = board.changeCount
  }
}

NSApplication.shared.setActivationPolicy(.accessory)
let watcher = Watcher()
watcher.start()
NSApplication.shared.run()
