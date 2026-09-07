import Foundation

/// Pure retry-state helper for durable media imports. CameraManager owns it on the serial session
/// queue, so repeated Retry taps can only start recovery items that are not already in flight.
struct RecoveryRetryState: Equatable {
    private(set) var inFlight = Set<URL>()

    mutating func begin(_ urls: [URL]) -> [URL] {
        var accepted: [URL] = []
        accepted.reserveCapacity(urls.count)
        for url in urls where inFlight.insert(url).inserted {
            accepted.append(url)
        }
        return accepted
    }

    mutating func finish(_ url: URL) {
        inFlight.remove(url)
    }

    func contains(_ url: URL) -> Bool {
        inFlight.contains(url)
    }
}
