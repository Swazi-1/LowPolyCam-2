import Foundation

/// Pure transaction-state helper. CameraManager uses the same rule for every hardware mutation:
/// once a mutation begins, any unsuccessful application must roll back to the last complete state.
struct CaptureConfigurationTransaction: Equatable {
    enum State: Equatable {
        case idle
        case applying
        case committed
        case rollingBack
        case rolledBack
    }

    private(set) var state: State = .idle

    mutating func begin() {
        state = .applying
    }

    mutating func finish(success: Bool) -> Bool {
        guard state == .applying else { return false }
        if success {
            state = .committed
            return false
        }
        state = .rollingBack
        return true
    }

    mutating func didRollback() {
        guard state == .rollingBack else { return }
        state = .rolledBack
    }
}
