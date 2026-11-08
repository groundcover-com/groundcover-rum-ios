import Foundation

/// `text` cut to `maxLength` UTF-16 units, as the other SDKs count, with `ellipsis` appended when
/// cut. A cut never splits a surrogate pair. Nil becomes `""`; anything else is stringified first.
func truncate(_ text: Any?, maxLength: Int = 10_000, ellipsis: String = "") -> String {
    guard let text else { return "" }
    let string = text as? String ?? String(describing: text)
    guard string.utf16.count > maxLength else { return string }
    let scalars = string.unicodeScalars
    var end = scalars.startIndex
    var units = 0
    while end < scalars.endIndex {
        let width = scalars[end].utf16.count
        if units + width > maxLength { break }
        units += width
        end = scalars.index(after: end)
    }
    return String(scalars[..<end]) + ellipsis
}

/// JavaScript's `\s`, so a label collapses the same on every SDK.
private let whitespace = CharacterSet(charactersIn: "\t\n\u{0B}\u{0C}\r \u{A0}\u{1680}")
    .union(CharacterSet(charactersIn: "\u{2000}"..."\u{200A}"))
    .union(CharacterSet(charactersIn: "\u{2028}\u{2029}\u{202F}\u{205F}\u{3000}\u{FEFF}"))

/// Runs of whitespace, newlines included, collapsed to one space and trimmed: a one-line label from
/// multi-line text.
func normalizeWhitespace(_ text: String?) -> String {
    (text ?? "").components(separatedBy: whitespace).filter { !$0.isEmpty }.joined(separator: " ")
}
