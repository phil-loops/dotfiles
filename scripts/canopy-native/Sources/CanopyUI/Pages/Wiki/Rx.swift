import Foundation

/// JS-flavoured regex helpers over NSRegularExpression (ICU), so the web app's string transforms
/// port line for line: `replace` with a closure is `String.replace(re, fn)` with the `g` flag.
enum Rx {
    private static var cache: [String: NSRegularExpression] = [:]
    private static let lock = NSLock()

    static func re(_ pattern: String) -> NSRegularExpression {
        lock.withLock {
            if let r = cache[pattern] { return r }
            let r = try! NSRegularExpression(pattern: pattern)
            cache[pattern] = r
            return r
        }
    }

    /// The groups of the first match (index 0 the whole match; nil for a group that didn't take part), or nil.
    static func exec(_ pattern: String, _ s: String) -> [String?]? {
        let ns = s as NSString
        guard let m = re(pattern).firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (0..<m.numberOfRanges).map { i in
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }
    }

    static func test(_ pattern: String, _ s: String) -> Bool { exec(pattern, s) != nil }

    /// Every match replaced by what `fn` makes of its groups (a group that didn't take part reads "").
    static func replace(_ s: String, _ pattern: String, _ fn: ([String]) -> String) -> String {
        let ns = s as NSString
        var out = ""
        var at = 0
        for m in re(pattern).matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: at, length: m.range.location - at))
            let groups = (0..<m.numberOfRanges).map { i -> String in
                let r = m.range(at: i)
                return r.location == NSNotFound ? "" : ns.substring(with: r)
            }
            out += fn(groups)
            at = m.range.location + m.range.length
        }
        return out + ns.substring(from: at)
    }

    /// `$1`-style template replacement, like JS's string replacement form.
    static func replace(_ s: String, _ pattern: String, template: String) -> String {
        let ns = s as NSString
        return re(pattern).stringByReplacingMatches(in: s, range: NSRange(location: 0, length: ns.length), withTemplate: template)
    }
}
