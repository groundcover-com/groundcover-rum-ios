import Foundation

// JSON for what the app hands the SDK unflattened: user properties, and whatever an enrichEvent,
// beforeSend or redact hook puts back.

private let maxJsonDataDepth = 32

/// `value` as plain JSON data: dictionaries with string keys, arrays and JSON scalars, anything
/// else as ``jsonLeaf(_:)`` writes it, a cycle marked `[Circular]`, and nesting past 32 levels cut.
/// For what the app hands the SDK to keep, made once, so a batch never fails on one odd value.
func toJsonData(_ value: Any?) -> Any {
    var seen = Set<ObjectIdentifier>()
    return toJsonData(value, seen: &seen, depth: 0)
}

/// `map` as ``toJsonData(_:)`` makes it.
func toJsonMap(_ map: [AnyHashable: Any]) -> [String: Any] {
    toJsonData(map) as? [String: Any] ?? [:]
}

/// Anything that isn't a dictionary or an array, as JSON can carry it: a non-finite number is
/// null, and anything but a JSON scalar its string form.
func jsonLeaf(_ value: Any) -> Any {
    switch value {
    // An Objective-C number, which may be a Bool in disguise.
    case let number as NSNumber where type(of: value) is AnyClass:
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue }
        if CFNumberIsFloatType(number) { return number.doubleValue.isFinite ? number : NSNull() }
        return number
    case let bool as Bool where type(of: value) == Bool.self:
        return bool
    case let string as String:
        return string
    case is Int, is Int8, is Int16, is Int32, is Int64, is UInt, is UInt8, is UInt16, is UInt32,
        is UInt64:
        return value
    // Wider integers (Int128, a BigInt) and Float16 don't bridge to NSNumber, and JSONSerialization
    // throws an Objective-C exception on them that nothing can catch.
    case let integer as any BinaryInteger:
        if let exact = Int64(exactly: integer) { return exact }
        if let exact = UInt64(exactly: integer) { return exact }
        return String(describing: value)
    case let float as any BinaryFloatingPoint:
        let double = Double(float)
        guard double.isFinite else { return NSNull() }
        return value is Double || value is Float || value is CGFloat ? value : double
    case is NSNull:
        return value
    default:
        return String(describing: value)
    }
}

/// `value` as JSON text, written as ``toJsonData(_:)`` makes it, keys sorted.
func encodeJson(_ value: Any?) -> String {
    guard
        let bytes = try? JSONSerialization.data(
            withJSONObject: toJsonData(value),
            options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes])
    else { return "null" }
    return String(decoding: bytes, as: UTF8.self)
}

/// `json` decoded, when it is a JSON object; nil for anything else, unreadable JSON included.
func decodeJsonObject(_ json: String) -> [String: Any]? {
    guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) else { return nil }
    return object as? [String: Any]
}

private func toJsonData(_ value: Any?, seen: inout Set<ObjectIdentifier>, depth: Int) -> Any {
    guard let value = unwrapped(value) else { return NSNull() }
    let dictionary = value as? [AnyHashable: Any]
    let array = dictionary == nil && !(value is String) ? elements(of: value) : nil
    guard dictionary != nil || array != nil else { return jsonLeaf(value) }
    if depth >= maxJsonDataDepth { return "[Depth Limit]" }

    // Only a reference type can contain itself: a Swift dictionary or array is a value.
    let identity = type(of: value) is AnyClass ? ObjectIdentifier(value as AnyObject) : nil
    if let identity {
        guard seen.insert(identity).inserted else { return "[Circular]" }
    }
    defer {
        if let identity { seen.remove(identity) }
    }

    if let dictionary {
        var out: [String: Any] = [:]
        for (key, child) in dictionary {
            out["\(key.base)"] = toJsonData(child, seen: &seen, depth: depth + 1)
        }
        return out
    }
    return array!.map { toJsonData($0, seen: &seen, depth: depth + 1) }
}

/// An array or a set as an array; nil for anything else.
func elements(of value: Any) -> [Any]? {
    if let array = value as? [Any] { return array }
    if let set = value as? Set<AnyHashable> { return Array(set) }
    if let set = value as? NSSet { return set.allObjects }
    return nil
}

private protocol AnyOptional {
    var wrapped: Any? { get }
}

extension Optional: AnyOptional {
    fileprivate var wrapped: Any? { map { $0 as Any } }
}

/// `value` without the optionals wrapped around it: an `Any` can hold `Int?.none`.
func unwrapped(_ value: Any?) -> Any? {
    guard let value else { return nil }
    guard let optional = value as? AnyOptional else { return value }
    return unwrapped(optional.wrapped)
}
