import Foundation

enum PreviewTransitionReason: String, Equatable {
    case lens
    case cameraFlip
    case whiteBalanceInput
    case configuration
}

struct PreviewTransitionRequest: Equatable {
    let id: UInt64
    let reason: PreviewTransitionReason
    let targetDeviceID: String?
    let blocksControls: Bool

    func bindingTargetDeviceID(_ deviceID: String) -> PreviewTransitionRequest {
        PreviewTransitionRequest(
            id: id, reason: reason, targetDeviceID: deviceID, blocksControls: blocksControls
        )
    }
}

/// Small identity-based state machine shared by the camera queue and preview UI.
/// It prevents an old completion from dismissing a newer transition and makes
/// cover acknowledgement / hardware commit / preview readiness explicit stages.
struct PreviewTransitionStateMachine {
    enum Stage: Equatable {
        case covering
        case covered
        case committed(deviceID: String)
    }

    private(set) var activeRequest: PreviewTransitionRequest?
    private(set) var stage: Stage?

    @discardableResult
    mutating func begin(_ request: PreviewTransitionRequest) -> PreviewTransitionRequest? {
        let replaced = activeRequest
        activeRequest = request
        stage = .covering
        return replaced
    }

    mutating func acknowledgeCovered(id: UInt64) -> Bool {
        guard activeRequest?.id == id else { return false }
        stage = .covered
        return true
    }

    mutating func hardwareCommitted(id: UInt64, deviceID: String) -> Bool {
        guard let activeRequest, activeRequest.id == id,
              activeRequest.targetDeviceID == nil || activeRequest.targetDeviceID == deviceID else { return false }
        self.activeRequest = activeRequest.bindingTargetDeviceID(deviceID)
        stage = .committed(deviceID: deviceID)
        return true
    }

    mutating func previewResumed(id: UInt64, deviceID: String) -> Bool {
        guard let activeRequest, activeRequest.id == id,
              activeRequest.targetDeviceID == deviceID,
              stage == .committed(deviceID: deviceID) else { return false }
        self.activeRequest = nil
        stage = nil
        return true
    }

    mutating func cancel(id: UInt64) -> Bool {
        guard activeRequest?.id == id else { return false }
        activeRequest = nil
        stage = nil
        return true
    }

    mutating func cancelAll() -> PreviewTransitionRequest? {
        let previous = activeRequest
        activeRequest = nil
        stage = nil
        return previous
    }
}
