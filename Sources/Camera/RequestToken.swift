import Foundation

/// Monotonic request generation with optional Extreme Diagnostics tracing. Successful validation
/// stays cheap; only token advances and stale rejections are logged so hot paths do not explode.
final class RequestToken {
    let name: String
    private let lock = NSLock()
    private var latest: UInt64 = 0

    init(_ name: String = "unnamed") {
        self.name = name
    }

    func next(reason: String? = nil) -> UInt64 {
        lock.lock()
        let previous = latest
        latest &+= 1
        let value = latest
        lock.unlock()
        if AppEventLog.extremeDiagnosticsEnabled {
            var fields = ["token": name, "before": String(previous), "after": String(value)]
            if let reason { fields["reason"] = reason }
            AppEventLog.deepEvent("REQUEST TOKEN ADVANCED", category: .request, fields: fields)
        }
        return value
    }

    func isLatest(_ id: UInt64) -> Bool {
        lock.lock()
        let value = latest
        lock.unlock()
        let matches = id == value
        if !matches, AppEventLog.extremeDiagnosticsEnabled {
            AppEventLog.staleRequest(token: name, requestID: id, latestID: value, operation: "isLatest")
        }
        return matches
    }

    func current() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }

    func isCurrent(_ id: UInt64?) -> Bool {
        guard let id else { return true }
        return isLatest(id)
    }
}
