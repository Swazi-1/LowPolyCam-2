import Foundation

/// Small value-type backpressure gate used on CameraManager's serial session queue.
/// It bounds expensive photo processing work without blocking AVFoundation callback threads.
struct BoundedInFlightGate: Equatable {
    let capacity: Int
    private(set) var inFlight: Int = 0

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    var hasCapacity: Bool { inFlight < capacity }

    mutating func reserve() -> Bool {
        guard hasCapacity else { return false }
        inFlight += 1
        return true
    }

    mutating func release() {
        inFlight = max(0, inFlight - 1)
    }
}
