import AppKit
import SwiftUI

/// The seam for big code and diff views: SwiftUI Text can't hold a 5k-line diff, NSTextView can.
/// Read-only, so the KeyMonitor keeps page keys working over it. The Review porter grows this
/// (attributed lines, gutters, line → stop mapping, hover positions for /lsp/*); the Tutor's code
/// pane reuses it.
public struct CodeTextView: NSViewRepresentable {
    public var text: NSAttributedString

    public init(_ text: NSAttributedString) { self.text = text }

    public init(plain: String, font: NSFont = Theme.nsMono(), color: NSColor = .textColor) {
        self.text = NSAttributedString(string: plain, attributes: [.font: font, .foregroundColor: color])
    }

    public func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let tv = scroll.documentView as! NSTextView
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.textContainerInset = NSSize(width: 8, height: 8)
        scroll.drawsBackground = false
        return scroll
    }

    public func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView, tv.attributedString() != text else { return }
        tv.textStorage?.setAttributedString(text)
    }
}
