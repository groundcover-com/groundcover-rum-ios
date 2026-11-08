import Foundation

/// JavaScript's `\s`, for patterns that must match as the other SDKs' do. ICU's `\s` differs at
/// the edges.
let jsWhitespaceClass =
    #"\t\n\x{0B}\f\r \x{A0}\x{1680}\x{2000}-\x{200A}\x{2028}\x{2029}\x{202F}\x{205F}\x{3000}\x{FEFF}"#

extension NSRegularExpression {
    /// A pattern the SDK ships, so one that doesn't compile is a bug caught by the first test that
    /// uses it.
    convenience init(sdkPattern pattern: String, options: Options = []) {
        // swift-format-ignore: NeverUseForceTry
        try! self.init(pattern: pattern, options: options)
    }

    func hasMatch(_ text: String) -> Bool {
        firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// `text` with each match replaced by what `transform` returns, given the match's capture
    /// groups (index 0 is the whole match; an unmatched group is "").
    func replacingMatches(in text: String, _ transform: ([String]) -> String) -> String {
        let source = text as NSString
        var out = ""
        var cursor = 0
        for match in matches(in: text, range: NSRange(location: 0, length: source.length)) {
            out += source.substring(
                with: NSRange(location: cursor, length: match.range.location - cursor))
            let groups = (0..<match.numberOfRanges).map { index -> String in
                let range = match.range(at: index)
                return range.location == NSNotFound ? "" : source.substring(with: range)
            }
            out += transform(groups)
            cursor = match.range.location + match.range.length
        }
        return out + source.substring(from: cursor)
    }
}
