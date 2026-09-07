import Foundation

/// Keeps one pending value while a serial consumer is busy. The consumer processes one value
/// per queue turn so capture/lifecycle work can run between interactive updates.
final class LatestValueMailbox<Value> {
    private let lock = NSLock()
    private var pending: Value?
    private var draining = false

    /// Returns true only when the caller must schedule a consumer.
    func submit(_ value: Value) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        pending = value
        guard !draining else { return false }
        draining = true
        return true
    }

    func take() -> Value? {
        lock.lock()
        defer { lock.unlock() }
        let value = pending
        pending = nil
        return value
    }

    /// Atomically consumes the pending value only when it belongs to the currently executing
    /// operation. This lets an optical handoff reconcile the latest same-gesture zoom before the
    /// preview is revealed without accidentally stealing a newer generation.
    func take(where predicate: (Value) -> Bool) -> Value? {
        lock.lock()
        defer { lock.unlock() }
        guard let value = pending, predicate(value) else { return nil }
        pending = nil
        return value
    }

    var isIdle: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !draining && pending == nil
    }

    /// Call after processing, even when the value was invalidated. The lock makes handing
    /// consumer ownership back to a concurrent producer atomic, preventing lost wakeups.
    func finish() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if pending != nil { return true }
        draining = false
        return false
    }
}
