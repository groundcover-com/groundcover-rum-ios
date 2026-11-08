import Foundation

/// Work scheduled for later, which can be called off.
protocol ScheduledWork {
    func cancel()
}

/// Where the core runs: one serial queue in the app, inline in tests. Every core object is
/// confined to it, so none of them locks.
protocol CoreExecutor: AnyObject {
    func execute(_ work: @escaping () -> Void)
    func schedule(afterMs delay: Int64, _ work: @escaping () -> Void) -> ScheduledWork
}

extension DispatchWorkItem: ScheduledWork {}

/// The core's serial queue.
final class QueueExecutor: CoreExecutor {
    private let queue: DispatchQueue
    private let key = DispatchSpecificKey<Void>()

    init(label: String) {
        queue = DispatchQueue(label: label, qos: .utility)
        queue.setSpecific(key: key, value: ())
    }

    /// Whether the caller is on this queue, where waiting on it would never return.
    var isCurrent: Bool { DispatchQueue.getSpecific(key: key) != nil }

    func execute(_ work: @escaping () -> Void) {
        queue.async(execute: work)
    }

    func schedule(afterMs delay: Int64, _ work: @escaping () -> Void) -> ScheduledWork {
        let item = DispatchWorkItem(block: work)
        queue.asyncAfter(deadline: .now() + .milliseconds(Int(delay)), execute: item)
        return item
    }

    /// Queues `work` and waits for it, at most `timeout` seconds. On the queue itself, from a hook,
    /// it doesn't wait: the work runs once the caller returns. The work runs at user-initiated
    /// priority, not the queue's utility: the caller (the app's main thread, in `start`) is
    /// blocked on it, and a semaphore lends the queue no priority of its own.
    func executeAndWait(timeout: TimeInterval, _ work: @escaping () -> Void) {
        let done = DispatchSemaphore(value: 0)
        queue.async(qos: .userInitiated, flags: .enforceQoS) {
            work()
            done.signal()
        }
        if !isCurrent { _ = done.wait(timeout: .now() + timeout) }
    }
}
