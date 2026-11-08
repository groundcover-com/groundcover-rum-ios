import Foundation

/// Remembers which objects this SDK has already attached something to. Kept apart from
/// `GCRumGestureTracker` because the bookkeeping can be wrong and is UIKit-free, so a unit test
/// can reach it. The key is the subtlety: `ObjectIdentifier` is derived from an ADDRESS, unique
/// only among LIVE objects, so a registry that never forgets would eventually claim to have seen
/// a window it never has and the caller would silently skip attaching. Entries therefore hold
/// their object WEAKLY, and a dead entry is evicted before any answer is given.
final class GCRumAttachmentRegistry<Value> {
    /// A weak box: `[ObjectIdentifier: Value]` alone would keep no trace of
    /// whether the keyed object is still there, and holding it strongly would keep
    /// every window this SDK ever saw alive.
    private struct Entry {
        weak var owner: AnyObject?
        let value: Value
    }

    private var entries: [ObjectIdentifier: Entry] = [:]

    /// Live entries only. Dead ones are gone by the time this returns.
    var count: Int {
        evictDeadEntries()
        return entries.count
    }

    /// Whether `owner` already has a value here.
    ///
    /// Evicts first, so a key left behind by a deallocated object can never be
    /// mistaken for this one — the reuse case, which is the whole point.
    func contains(_ owner: AnyObject) -> Bool {
        evictDeadEntries()
        return entries[ObjectIdentifier(owner)] != nil
    }

    func value(for owner: AnyObject) -> Value? {
        evictDeadEntries()
        return entries[ObjectIdentifier(owner)]?.value
    }

    func set(_ value: Value, for owner: AnyObject) {
        evictDeadEntries()
        entries[ObjectIdentifier(owner)] = Entry(owner: owner, value: value)
    }

    /// Removes one entry and hands back its value, so a caller that has to undo
    /// the attachment (remove a recognizer) can still reach it.
    @discardableResult
    func remove(for owner: AnyObject) -> Value? {
        let removed = entries.removeValue(forKey: ObjectIdentifier(owner))
        evictDeadEntries()
        return removed?.value
    }

    /// Every live value, for teardown.
    func allValues() -> [Value] {
        evictDeadEntries()
        return entries.values.map(\.value)
    }

    func removeAll() {
        entries.removeAll()
    }

    /// An entry whose object is gone describes an attachment to something that no
    /// longer exists. Nothing can be done with it, and keeping it is what lets a
    /// reused address answer for a window that was never attached to.
    private func evictDeadEntries() {
        entries = entries.filter { $0.value.owner != nil }
    }
}
