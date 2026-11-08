import Foundation

// JSON as JavaScript reads and writes it, for a body the SDK rewrites: keys stay in their order,
// numbers come back as JSON.stringify prints them, and `/` is not escaped. JSONSerialization does
// none of the three.

/// A JSON object, its keys in their original order.
struct JsJsonObject {
    var entries: [(key: String, value: Any)]
}

/// How deep ``parseJsJson(_:)`` goes before it treats the text as not JSON: each level is a stack
/// frame, and the core queue's GCD thread has 512 KB of stack. The Kotlin twin's limit too.
let maxJsJsonDepth = 64

/// Whether `text` opens more than `limit` objects or arrays inside one another, counting brackets
/// outside strings. Linear, with no recursion, so it is safe at any depth.
func jsJsonNestsDeeperThan(_ text: String, _ limit: Int) -> Bool {
    var depth = 0
    var inString = false
    var escaped = false
    for byte in text.utf8 {
        if inString {
            if escaped {
                escaped = false
            } else if byte == UInt8(ascii: "\\") {
                escaped = true
            } else if byte == UInt8(ascii: "\"") {
                inString = false
            }
            continue
        }
        switch byte {
        case UInt8(ascii: "\""): inString = true
        case UInt8(ascii: "{"), UInt8(ascii: "["):
            depth += 1
            if depth > limit { return true }
        case UInt8(ascii: "}"), UInt8(ascii: "]"): depth -= 1
        default: break
        }
    }
    return false
}

/// `text` parsed, objects as ``JsJsonObject``, numbers as Int64 when whole and in range and Double
/// otherwise, null as NSNull. Nil when it isn't JSON.
func parseJsJson(_ text: String) -> Any? {
    var parser = JsJsonParser(bytes: Array(text.utf8))
    guard let value = parser.parseValue(depth: 0) else { return nil }
    parser.skipWhitespace()
    return parser.index == parser.bytes.count ? value : nil
}

/// `value` as JSON.stringify writes it: ``JsJsonObject`` keys in order, dictionaries' keys sorted,
/// a non-finite number as null, anything that isn't JSON as ``jsonLeaf(_:)`` writes it.
func writeJsJson(_ value: Any?) -> String {
    var out = ""
    writeJsJson(value, into: &out)
    return out
}

private func writeJsJson(_ value: Any?, into out: inout String) {
    switch value {
    case nil, is NSNull:
        out += "null"
    case let object as JsJsonObject:
        out += "{"
        for (index, entry) in object.entries.enumerated() {
            if index > 0 { out += "," }
            writeJsString(entry.key, into: &out)
            out += ":"
            writeJsJson(entry.value, into: &out)
        }
        out += "}"
    case let dictionary as [String: Any]:
        writeJsJson(
            JsJsonObject(entries: dictionary.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }),
            into: &out)
    case let array as [Any]:
        out += "["
        for (index, item) in array.enumerated() {
            if index > 0 { out += "," }
            writeJsJson(item, into: &out)
        }
        out += "]"
    default:
        let leaf = jsonLeaf(value!)
        switch leaf {
        case let bool as Bool where type(of: leaf) == Bool.self:
            out += bool ? "true" : "false"
        case let string as String:
            writeJsString(string, into: &out)
        case let number as NSNumber where type(of: leaf) is AnyClass:
            out +=
                CFNumberIsFloatType(number)
                ? jsNumberString(number.doubleValue) : number.stringValue
        case let integer as any BinaryInteger:
            out += "\(integer)"
        case let float as any BinaryFloatingPoint:
            out += jsNumberString(Double(float))
        default:
            out += "null"
        }
    }
}

private func writeJsString(_ string: String, into out: inout String) {
    out += "\""
    for scalar in string.unicodeScalars {
        switch scalar {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\u{08}": out += "\\b"
        case "\u{0C}": out += "\\f"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        case let control where control.value < 0x20:
            out += String(format: "\\u%04x", control.value)
        default: out.unicodeScalars.append(scalar)
        }
    }
    out += "\""
}

/// `value` as JavaScript's Number#toString prints it: whole numbers up to 2^53 without a point,
/// plain digits from 1e-7 to 1e21, an exponent outside that range.
func jsNumberString(_ value: Double) -> String {
    guard value.isFinite else { return "null" }
    if value == value.rounded(), abs(value) <= 9_007_199_254_740_991 {
        return String(Int64(value))
    }
    let negative = value < 0
    // Swift's description is the shortest round-tripping form, as JavaScript's is.
    let text = String(describing: abs(value))
    let parts = text.split(separator: "e", maxSplits: 1)
    let exponent = parts.count == 2 ? Int(parts[1]) ?? 0 : 0
    let mantissa = parts[0].split(separator: ".", maxSplits: 1)
    let whole = String(mantissa[0])
    var digits = Array(whole + (mantissa.count == 2 ? String(mantissa[1]) : ""))
    var point = whole.count + exponent
    while digits.first == "0", digits.count > 1 {
        digits.removeFirst()
        point -= 1
    }
    while digits.last == "0", digits.count > 1 { digits.removeLast() }

    let k = digits.count
    let n = point
    let string = String(digits)
    let body: String
    if k <= n && n <= 21 {
        body = string + String(repeating: "0", count: n - k)
    } else if 0 < n && n <= 21 {
        body = String(digits[0..<n]) + "." + String(digits[n...])
    } else if -6 < n && n <= 0 {
        body = "0." + String(repeating: "0", count: -n) + string
    } else {
        let e = n - 1
        let sign = e < 0 ? "-" : "+"
        body = (k == 1 ? string : "\(digits[0]).\(String(digits[1...]))") + "e\(sign)\(abs(e))"
    }
    return negative ? "-" + body : body
}

private struct JsJsonParser {
    let bytes: [UInt8]
    var index = 0

    private static let maxDepth = maxJsJsonDepth

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    mutating func skipWhitespace() {
        while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
    }

    mutating func parseValue(depth: Int) -> Any? {
        // Inclusive, so whatever this rejects for depth, jsJsonNestsDeeperThan flags.
        guard depth <= Self.maxDepth else { return nil }
        skipWhitespace()
        guard index < bytes.count else { return nil }
        switch bytes[index] {
        case UInt8(ascii: "{"): return parseObject(depth: depth)
        case UInt8(ascii: "["): return parseArray(depth: depth)
        case UInt8(ascii: "\""): return parseString()
        case UInt8(ascii: "t"): return parseLiteral("true", true)
        case UInt8(ascii: "f"): return parseLiteral("false", false)
        case UInt8(ascii: "n"): return parseLiteral("null", NSNull())
        default: return parseNumber()
        }
    }

    private mutating func parseLiteral(_ literal: String, _ value: Any) -> Any? {
        let expected = Array(literal.utf8)
        guard index + expected.count <= bytes.count,
            Array(bytes[index..<index + expected.count]) == expected
        else { return nil }
        index += expected.count
        return value
    }

    private mutating func parseObject(depth: Int) -> Any? {
        index += 1
        var entries: [(key: String, value: Any)] = []
        skipWhitespace()
        if index < bytes.count, bytes[index] == UInt8(ascii: "}") {
            index += 1
            return JsJsonObject(entries: entries)
        }
        while true {
            skipWhitespace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: "\""),
                let key = parseString()
            else { return nil }
            skipWhitespace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { return nil }
            index += 1
            guard let value = parseValue(depth: depth + 1) else { return nil }
            // A repeated key keeps its first place and its last value, as JSON.parse does.
            if let existing = entries.firstIndex(where: { $0.key == key }) {
                entries[existing].value = value
            } else {
                entries.append((key, value))
            }
            skipWhitespace()
            guard index < bytes.count else { return nil }
            if bytes[index] == UInt8(ascii: ",") {
                index += 1
            } else if bytes[index] == UInt8(ascii: "}") {
                index += 1
                return JsJsonObject(entries: entries)
            } else {
                return nil
            }
        }
    }

    private mutating func parseArray(depth: Int) -> Any? {
        index += 1
        var items: [Any] = []
        skipWhitespace()
        if index < bytes.count, bytes[index] == UInt8(ascii: "]") {
            index += 1
            return items
        }
        while true {
            guard let item = parseValue(depth: depth + 1) else { return nil }
            items.append(item)
            skipWhitespace()
            guard index < bytes.count else { return nil }
            if bytes[index] == UInt8(ascii: ",") {
                index += 1
            } else if bytes[index] == UInt8(ascii: "]") {
                index += 1
                return items
            } else {
                return nil
            }
        }
    }

    private mutating func parseString() -> String? {
        index += 1
        var utf8: [UInt8] = []
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            switch byte {
            case UInt8(ascii: "\""):
                return String(decoding: utf8, as: UTF8.self)
            case UInt8(ascii: "\\"):
                guard index < bytes.count else { return nil }
                let escape = bytes[index]
                index += 1
                switch escape {
                case UInt8(ascii: "\""): utf8.append(0x22)
                case UInt8(ascii: "\\"): utf8.append(0x5C)
                case UInt8(ascii: "/"): utf8.append(0x2F)
                case UInt8(ascii: "b"): utf8.append(0x08)
                case UInt8(ascii: "f"): utf8.append(0x0C)
                case UInt8(ascii: "n"): utf8.append(0x0A)
                case UInt8(ascii: "r"): utf8.append(0x0D)
                case UInt8(ascii: "t"): utf8.append(0x09)
                case UInt8(ascii: "u"):
                    guard let scalar = parseUnicodeEscape() else { return nil }
                    utf8.append(contentsOf: Array(String(scalar).utf8))
                default: return nil
                }
            case 0..<0x20:
                return nil
            default:
                utf8.append(byte)
            }
        }
        return nil
    }

    // `\uXXXX`, a surrogate pair joined, a lone surrogate as U+FFFD.
    private mutating func parseUnicodeEscape() -> Unicode.Scalar? {
        guard let high = readHex4() else { return nil }
        if (0xD800...0xDBFF).contains(high), index + 1 < bytes.count,
            bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u")
        {
            let save = index
            index += 2
            if let low = readHex4(), (0xDC00...0xDFFF).contains(low) {
                return Unicode.Scalar(0x10000 + ((high - 0xD800) << 10) + (low - 0xDC00))
            }
            index = save
        }
        return Unicode.Scalar(high) ?? "\u{FFFD}"
    }

    private mutating func readHex4() -> UInt32? {
        guard index + 4 <= bytes.count,
            let value = UInt32(String(decoding: bytes[index..<index + 4], as: UTF8.self), radix: 16)
        else { return nil }
        index += 4
        return value
    }

    private mutating func parseNumber() -> Any? {
        let start = index
        if index < bytes.count, bytes[index] == UInt8(ascii: "-") { index += 1 }
        var isInteger = true
        while index < bytes.count {
            let byte = bytes[index]
            if (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) {
                index += 1
            } else if [
                UInt8(ascii: "."), UInt8(ascii: "e"), UInt8(ascii: "E"), UInt8(ascii: "+"),
                UInt8(ascii: "-"),
            ]
            .contains(byte) {
                isInteger = false
                index += 1
            } else {
                break
            }
        }
        let text = String(decoding: bytes[start..<index], as: UTF8.self)
        guard !text.isEmpty, text != "-" else { return nil }
        if isInteger, let integer = Int64(text) { return integer }
        // Past the double range it is ±infinity, as JSON.parse reads it.
        return Double(text)
    }
}
