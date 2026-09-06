import Foundation

/// Single UI-facing recording state. Operational flags such as segment continuation remain
/// separate because they describe work, not what phase the recorder is in.
enum RecordingLifecycle: Equatable {
    case idle
    case starting
    case recording
    case stopping
    case saving
    case finalizing

    var isRecording: Bool { self == .recording }
    var isStarting: Bool { self == .starting }
    var isFinalizing: Bool {
        switch self {
        case .stopping, .saving, .finalizing: return true
        default: return false
        }
    }

    var blocksCameraReconfiguration: Bool { self != .idle }
}

/// Non-UI recording work state. Mutations go through named transitions so CameraManager cannot
/// accidentally create an impossible combination of otherwise unrelated booleans.
struct RecordingOperationContext {
    private(set) var requested = false
    private(set) var startIssued = false
    private(set) var segmentActive = false
    private(set) var finalizationPending = false
    private(set) var continuingSegment = false
    private(set) var splitSeconds: Double = 0
    private(set) var discardOnFinish = false

    mutating func begin(splitSeconds: Double) {
        requested = true
        startIssued = false
        segmentActive = false
        finalizationPending = false
        continuingSegment = false
        discardOnFinish = false
        self.splitSeconds = splitSeconds
    }

    mutating func markStartIssued() {
        startIssued = true
    }

    mutating func markStartConfirmed() {
        startIssued = false
        segmentActive = true
    }

    mutating func requestFinalStop() {
        requested = false
        continuingSegment = false
        finalizationPending = true
    }

    mutating func cancelSegmentContinuation() {
        continuingSegment = false
    }

    mutating func markSegmentBoundary() {
        continuingSegment = true
    }

    mutating func consumeSegmentContinuation(successful: Bool, sessionRunning: Bool) -> Bool {
        let shouldContinue = successful && requested && continuingSegment && sessionRunning
        // didFinish is the terminal callback for this start request even if AVFoundation never
        // delivered didStart (for example, an immediate startup failure).
        startIssued = false
        continuingSegment = false
        segmentActive = false
        return shouldContinue
    }

    mutating func markDiscardOnFinish() {
        discardOnFinish = true
    }

    /// Cancels a startup that has not reached `isRecording` yet. Returns true when
    /// AVCaptureMovieFileOutput already owns a start request and a delegate cleanup is expected.
    /// When a previous split segment already exists, keep the session in finalization instead of
    /// briefly returning to idle while that earlier segment is still being saved.
    mutating func cancelPendingStart(finalizeExistingSession: Bool = false) -> Bool {
        let issued = startIssued
        requested = false
        continuingSegment = false
        if issued {
            finalizationPending = true
            discardOnFinish = true
        } else if finalizeExistingSession {
            startIssued = false
            segmentActive = false
            finalizationPending = true
            splitSeconds = 0
            discardOnFinish = false
        } else {
            reset()
        }
        return issued
    }

    /// Completes cleanup for a canceled start that AVFoundation had already accepted. A canceled
    /// first segment can return directly to idle; a canceled split continuation must keep waiting
    /// for already-finished segments to complete their Photos imports.
    mutating func finishDiscardedSegment(finalizeExistingSession: Bool) {
        if finalizeExistingSession {
            requested = false
            startIssued = false
            segmentActive = false
            finalizationPending = true
            continuingSegment = false
            splitSeconds = 0
            discardOnFinish = false
        } else {
            reset()
        }
    }

    mutating func reset() {
        requested = false
        startIssued = false
        segmentActive = false
        finalizationPending = false
        continuingSegment = false
        splitSeconds = 0
        discardOnFinish = false
    }
}
