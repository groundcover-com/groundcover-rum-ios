import Foundation

private let maxFormatDepth = 10

/// What ``EventEnricher/enrich(_:)`` takes. One shaper per captured signal builds it; the enricher
/// adds ids, a timestamp and the platform's attributes.
struct EnrichInput {
    var type: String
    var attributes: [String: Any] = [:]

    /// When it happened (ns), or nil for now; a network event's start.
    var timestamp: Int64?

    /// A network event's end (ns).
    var endTimestamp: Int64?
    var spanName: String?
    var traceId: String?
    var spanId: String?
}

/// Turns a built event into a wire event: ids, a timestamp, dot-flattened attributes, and the
/// platform's own attributes (the current screen) merged last, so they win over a user attribute
/// of the same name.
final class EventEnricher {
    private let ids: IdGenerator
    private let clock: RumClock
    private let platformAttributes: (() throws -> [String: Any])?

    /// The keys `platformAttributes` stamps. Paths that merge free-form user attributes into an
    /// event strip these first.
    let reservedAttributeKeys: [String]

    init(
        idGenerator: IdGenerator,
        clock: @escaping RumClock,
        platformAttributes: (() throws -> [String: Any])? = nil,
        reservedAttributeKeys: [String] = []
    ) {
        self.ids = idGenerator
        self.clock = clock
        self.platformAttributes = platformAttributes
        self.reservedAttributeKeys = reservedAttributeKeys
    }

    private func platform() -> [String: Any] {
        guard let platformAttributes else { return [:] }
        do {
            return try platformAttributes()
        } catch {
            RumDiagnostics.shared.log(
                "[event-enricher] platform attribute contributor threw; continuing without it",
                detail: error)
            return [:]
        }
    }

    func enrich(_ input: EnrichInput) -> RumEvent {
        let now = msToNs(clock())
        let event = RumEvent(
            type: input.type,
            id: ids.generateId(),
            spanId: nonEmpty(input.spanId) ?? ids.generateSpanId(),
            parentSpanId: "",
            traceId: nonEmpty(input.traceId) ?? ids.generateTraceId(),
            spanName: nonEmpty(input.spanName),
            attributes: flattenAttributes(input.attributes).merging(platform()) { _, platform in
                platform
            })
        if input.type == "network" {
            event.startTimestamp = validTimestamp(input.timestamp, fallback: now)
            event.endTimestamp = input.endTimestamp
        } else {
            event.timestamp = validTimestamp(input.timestamp, fallback: now)
        }
        return event
    }
}

private func nonEmpty(_ value: String?) -> String? {
    guard let value, !value.isEmpty else { return nil }
    return value
}

/// A caller-supplied occurrence time (ns), or `fallback` when it is not usable. 0 is a legitimate
/// value; a negative one is not.
private func validTimestamp(_ supplied: Int64?, fallback: Int64) -> Int64 {
    guard let supplied, supplied >= 0 else { return fallback }
    return supplied
}

/// Dot-flattens nested dictionaries (`["a": ["b": 1]]` to `["a.b": 1]`). An array keeps its place,
/// and each dictionary inside it is flattened under `key[index]`, which is the shape the wire's
/// stack traces take; a set is an array. Values JSON cannot carry are made safe here, once, by
/// ``jsonLeaf(_:)``.
func flattenAttributes(_ object: [AnyHashable: Any]) -> [String: Any] {
    var seen = Set<ObjectIdentifier>()
    return flatten(object, prefix: "", seen: &seen, depth: 0)
}

private func flatten(
    _ object: Any, prefix: String, seen: inout Set<ObjectIdentifier>, depth: Int
) -> [String: Any] {
    if depth >= maxFormatDepth {
        return [prefix.isEmpty ? "depth_limit" : prefix: "[Depth Limit]"]
    }
    let identity = identityOf(object)
    if let identity {
        guard seen.insert(identity).inserted else {
            return [prefix.isEmpty ? "circular_reference" : prefix: "[Circular]"]
        }
    }
    defer {
        if let identity { seen.remove(identity) }
    }
    var out: [String: Any] = [:]
    for (rawKey, wrappedValue) in object as? [AnyHashable: Any] ?? [:] {
        let value: Any = unwrapped(wrappedValue) ?? NSNull()
        let key = prefix.isEmpty ? "\(rawKey.base)" : "\(prefix).\(rawKey.base)"
        if let map = asMap(value) {
            out.merge(flatten(map, prefix: key, seen: &seen, depth: depth + 1)) { $1 }
        } else if let list = asList(value) {
            out[key] = flattenList(value, list, key: key, seen: &seen, depth: depth)
        } else {
            out[key] = jsonLeaf(value)
        }
    }
    return out
}

/// An array's items, each dictionary among them flattened under `key[index]`.
private func flattenList(
    _ original: Any, _ list: [Any], key: String, seen: inout Set<ObjectIdentifier>, depth: Int
) -> Any {
    let identity = identityOf(original)
    if let identity {
        guard seen.insert(identity).inserted else { return "[Circular]" }
    }
    defer {
        if let identity { seen.remove(identity) }
    }
    return list.enumerated().map { index, wrappedItem -> Any in
        let item: Any = unwrapped(wrappedItem) ?? NSNull()
        if let map = asMap(item) {
            return flatten(map, prefix: "\(key)[\(index)]", seen: &seen, depth: depth + 1)
        }
        if let inner = asList(item) {
            if let innerIdentity = identityOf(item), seen.contains(innerIdentity) {
                return "[Circular]"
            }
            let indexed = Dictionary(
                uniqueKeysWithValues: inner.enumerated().map { ($0.offset, $0.element) })
            return flatten(indexed, prefix: "\(key)[\(index)]", seen: &seen, depth: depth + 1)
        }
        return jsonLeaf(item)
    }
}

// Only a reference type can contain itself: a Swift dictionary or array is a value.
private func identityOf(_ value: Any) -> ObjectIdentifier? {
    type(of: value) is AnyClass ? ObjectIdentifier(value as AnyObject) : nil
}

private func asMap(_ value: Any) -> Any? {
    value is [AnyHashable: Any] ? value : nil
}

private func asList(_ value: Any) -> [Any]? {
    if value is String { return nil }
    if let array = value as? [Any] { return array }
    if let set = value as? Set<AnyHashable> { return Array(set) }
    if let set = value as? NSSet { return set.allObjects }
    return nil
}
