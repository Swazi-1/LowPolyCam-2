import Foundation
import os

protocol PreviewTransitionPresenting: AnyObject {
    func preparePreviewTransition(_ request: PreviewTransitionRequest, covered: @escaping (UInt64) -> Void)
    func commitPreviewTransition(_ request: PreviewTransitionRequest)
    func finishPreviewTransition(id: UInt64)
    func cancelPreviewTransition(id: UInt64, keepCoverForReplacement: Bool)
}

/// Main-thread UI coordinator. CameraManager owns hardware/request validity; this object owns
/// only the reusable visual cover and identity checks for the preview side of a handoff.
final class PreviewTransitionController {
    private weak var presenter: PreviewTransitionPresenting?
    private var state = PreviewTransitionStateMachine()
    private var watchdogs: [UInt64: DispatchWorkItem] = [:]
    private var ownerCancellationCallbacks: [UInt64: (UInt64) -> Void] = [:]
#if DEBUG
    private let transitionLog = OSLog(subsystem: "com.swazi.LowPolyCam", category: "PreviewTransition")
    private let transitionLogger = Logger(subsystem: "com.swazi.LowPolyCam", category: "PreviewTransition")
    private var diagnosticIDs: [UInt64: OSSignpostID] = [:]
#endif

    var hasActiveTransition: Bool { state.activeRequest != nil }
    var activeTransitionID: UInt64? { state.activeRequest?.id }

    func attach(_ presenter: PreviewTransitionPresenting) {
        dispatchPrecondition(condition: .onQueue(.main))
        self.presenter = presenter
    }

    func detach(_ presenter: PreviewTransitionPresenting) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard self.presenter === presenter else { return }
        if let active = state.cancelAll() {
            watchdogs.removeValue(forKey: active.id)?.cancel()
            presenter.cancelPreviewTransition(id: active.id, keepCoverForReplacement: false)
            let notifyOwner = ownerCancellationCallbacks.removeValue(forKey: active.id)
            finishDiagnostics(id: active.id, result: "view-detached")
            notifyOwner?(active.id)
        }
        self.presenter = nil
    }

    func prepare(
        _ request: PreviewTransitionRequest,
        covered: @escaping (UInt64) -> Void,
        watchdogFired: @escaping (UInt64) -> Void
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        let replaced = state.begin(request)
        if let replaced {
            watchdogs.removeValue(forKey: replaced.id)?.cancel()
            ownerCancellationCallbacks.removeValue(forKey: replaced.id)
            presenter?.cancelPreviewTransition(id: replaced.id, keepCoverForReplacement: true)
            finishDiagnostics(id: replaced.id, result: "replaced")
        }
        ownerCancellationCallbacks[request.id] = watchdogFired
        beginDiagnostics(request)

        let acknowledge: (UInt64) -> Void = { [weak self] id in
            guard let self, self.state.acknowledgeCovered(id: id) else { return }
#if DEBUG
            if let signpostID = self.diagnosticIDs[id] {
                os_signpost(.event, log: self.transitionLog, name: "CoverInstalled", signpostID: signpostID)
                self.transitionLogger.debug("cover installed id=\(id)")
            }
#endif
            covered(id)
        }
        if let presenter {
            presenter.preparePreviewTransition(request, covered: acknowledge)
        } else {
            DispatchQueue.main.async { acknowledge(request.id) }
        }

        let watchdog = DispatchWorkItem { [weak self] in
            guard let self, self.state.activeRequest?.id == request.id else { return }
            _ = self.state.cancel(id: request.id)
            self.presenter?.cancelPreviewTransition(id: request.id, keepCoverForReplacement: false)
            self.watchdogs.removeValue(forKey: request.id)
            self.ownerCancellationCallbacks.removeValue(forKey: request.id)
            self.finishDiagnostics(id: request.id, result: "watchdog")
            watchdogFired(request.id)
        }
        watchdogs[request.id] = watchdog
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: watchdog)
    }

    func hardwareCommitted(id: UInt64, deviceID: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard state.hardwareCommitted(id: id, deviceID: deviceID), let request = state.activeRequest else { return }
#if DEBUG
        if let signpostID = diagnosticIDs[id] {
            os_signpost(.event, log: transitionLog, name: "HardwareCommitted", signpostID: signpostID)
            transitionLogger.debug("hardware committed id=\(id) device=\(deviceID, privacy: .public)")
        }
#endif
        presenter?.commitPreviewTransition(request)
    }

    func reportPreviewResumed(id: UInt64, deviceID: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard state.previewResumed(id: id, deviceID: deviceID) else { return }
        watchdogs.removeValue(forKey: id)?.cancel()
        ownerCancellationCallbacks.removeValue(forKey: id)
#if DEBUG
        if let signpostID = diagnosticIDs[id] {
            os_signpost(.event, log: transitionLog, name: "PreviewReady", signpostID: signpostID)
            transitionLogger.debug("preview ready id=\(id) device=\(deviceID, privacy: .public)")
        }
#endif
        presenter?.finishPreviewTransition(id: id)
        finishDiagnostics(id: id, result: "ready")
    }

    func cancel(id: UInt64, keepCoverForReplacement: Bool = false) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard state.cancel(id: id) else { return }
        watchdogs.removeValue(forKey: id)?.cancel()
        ownerCancellationCallbacks.removeValue(forKey: id)
        presenter?.cancelPreviewTransition(id: id, keepCoverForReplacement: keepCoverForReplacement)
        finishDiagnostics(id: id, result: "cancel")
    }

    func cancelAll() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let active = state.cancelAll() else { return }
        watchdogs.values.forEach { $0.cancel() }
        watchdogs.removeAll()
        ownerCancellationCallbacks.removeValue(forKey: active.id)
        presenter?.cancelPreviewTransition(id: active.id, keepCoverForReplacement: false)
        finishDiagnostics(id: active.id, result: "cancel-all")
    }

#if DEBUG
    private func beginDiagnostics(_ request: PreviewTransitionRequest) {
        let signpostID = OSSignpostID(log: transitionLog)
        diagnosticIDs[request.id] = signpostID
        os_signpost(.begin, log: transitionLog, name: "PreviewTransition", signpostID: signpostID)
        transitionLogger.debug(
            "transition request id=\(request.id) reason=\(request.reason.rawValue, privacy: .public) target=\(request.targetDeviceID ?? "pending", privacy: .public)"
        )
    }

    private func finishDiagnostics(id: UInt64, result: String) {
        guard let signpostID = diagnosticIDs.removeValue(forKey: id) else { return }
        os_signpost(.end, log: transitionLog, name: "PreviewTransition", signpostID: signpostID)
        transitionLogger.debug("transition end id=\(id) result=\(result, privacy: .public)")
    }
#else
    private func beginDiagnostics(_ request: PreviewTransitionRequest) {}
    private func finishDiagnostics(id: UInt64, result: String) {}
#endif
}
