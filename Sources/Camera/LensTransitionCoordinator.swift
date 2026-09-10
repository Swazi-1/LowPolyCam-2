import AVFoundation
import Foundation

final class LensTransitionCoordinator {
    typealias CaptureMode = CameraManager.CaptureMode
    typealias CameraPosition = CameraManager.CameraPosition
    typealias SlowMotionFrameRate = CameraManager.SlowMotionFrameRate

    struct Request {
        let id: UInt64
        let mode: CaptureMode
        let requestedZoom: CGFloat
        let position: CameraPosition
        let codec: String
        let videoResolution: VideoResolution
        let videoFrameRate: VideoFrameRate
        let slowMotionResolution: VideoResolution
        let slowMotionFrameRate: SlowMotionFrameRate
        let targetDeviceID: String
    }

    struct PreparedTransition {
        let request: Request
        let device: AVCaptureDevice
        let format: AVCaptureDevice.Format
        let frameRate: Double
        let replacementInput: AVCaptureDeviceInput?
    }

    private let sessionQueue: DispatchQueue
    private let zoomRequests: RequestToken
    private let onTransitioningChanged: (Bool) -> Void
    private var activeRequestID: UInt64?
    private var activeTraceStart: TimeInterval?

    private func traceID(_ requestID: UInt64) -> String { "ZOOM-\(requestID)" }

    init(
        sessionQueue: DispatchQueue,
        zoomRequests: RequestToken,
        onTransitioningChanged: @escaping (Bool) -> Void
    ) {
        self.sessionQueue = sessionQueue
        self.zoomRequests = zoomRequests
        self.onTransitioningChanged = onTransitioningChanged
    }

    var hasActiveTransition: Bool {
        activeRequestID != nil
    }

    func isActive(_ requestID: UInt64) -> Bool {
        activeRequestID == requestID
    }

    func takeOwnership(of requestID: UInt64) {
        let previous = activeRequestID
        activeRequestID = requestID
        AppEventLog.deepEvent("LENS TRANSITION OWNERSHIP", category: .lens, traceID: traceID(requestID), fields: [
            "previousRequest": previous.map(String.init) ?? "none",
            "newRequest": String(requestID)
        ])
    }

    func shouldUseCoveredPhysicalHandoff(
        captureMode: CaptureMode,
        cameraPosition: CameraPosition,
        selectedResolution: VideoResolution,
        selectedFrameRate: VideoFrameRate
    ) -> Bool {
        guard cameraPosition == .back else { return false }
        switch captureMode {
        case .sloMo:
            return true
        case .video:
            return selectedResolution == .p4k && selectedFrameRate == .fps60
        case .photo:
            return false
        }
    }

    func isRearVirtualLensSystem(_ device: AVCaptureDevice) -> Bool {
        guard device.position == .back, device.isVirtualDevice else { return false }
        let hasWide = device.constituentDevices.contains { $0.deviceType == .builtInWideAngleCamera }
        let hasUltraWide = device.constituentDevices.contains { $0.deviceType == .builtInUltraWideCamera }
        return hasWide && hasUltraWide && !device.virtualDeviceSwitchOverVideoZoomFactors.isEmpty
    }

    func shouldUseVirtual4K60Handoff(
        on device: AVCaptureDevice,
        captureMode: CaptureMode,
        cameraPosition: CameraPosition,
        selectedResolution: VideoResolution,
        selectedFrameRate: VideoFrameRate,
        usesAutoWhiteBalance: Bool,
        formatSelector: CameraFormatSelector
    ) -> Bool {
        guard captureMode == .video,
              cameraPosition == .back,
              selectedResolution == .p4k,
              selectedFrameRate == .fps60,
              usesAutoWhiteBalance,
              isRearVirtualLensSystem(device) else { return false }
        return formatSelector.format(device.activeFormat, supports: .p4k, at: .fps60) && formatSelector.formatSupportsSelectedCodec(device.activeFormat)
    }

    func crossesVirtualBoundary(
        on device: AVCaptureDevice,
        from: CGFloat,
        to: CGFloat,
        displayedZoomFactor: (CGFloat, AVCaptureDevice) -> CGFloat
    ) -> Bool {
        guard isRearVirtualLensSystem(device), abs(to - from) > 0.001 else { return false }
        for factor in device.virtualDeviceSwitchOverVideoZoomFactors {
            let boundary = displayedZoomFactor(CGFloat(factor.doubleValue), device)
            if (from < boundary && to >= boundary) || (from >= boundary && to < boundary) {
                return true
            }
        }
        return false
    }

    func supportedPhysicalLensDevices(
        from devices: [AVCaptureDevice],
        captureMode: CaptureMode,
        selectedResolution: VideoResolution,
        selectedFrameRate: VideoFrameRate,
        selectedSlowMotionResolution: VideoResolution,
        selectedSlowMotionFrameRate: SlowMotionFrameRate,
        formatSelector: CameraFormatSelector
    ) -> [AVCaptureDevice] {
        let physicalDevices = devices.filter { !$0.isVirtualDevice }
        switch captureMode {
        case .video:
            return physicalDevices.filter { device in
                device.formats.contains {
                    formatSelector.format($0, supports: selectedResolution, at: selectedFrameRate) && formatSelector.formatSupportsSelectedCodec($0)
                }
            }
        case .sloMo:
            return physicalDevices.filter { device in
                device.formats.contains {
                    formatSelector.supportsSlowMotion($0, resolution: selectedSlowMotionResolution, frameRate: selectedSlowMotionFrameRate)
                }
            }
        case .photo:
            return physicalDevices
        }
    }

    func preparePhysicalHandoff(
        _ request: Request,
        devices: [AVCaptureDevice],
        currentDeviceID: String?,
        selectedResolution: VideoResolution,
        selectedFrameRate: VideoFrameRate,
        selectedSlowMotionResolution: VideoResolution,
        selectedSlowMotionFrameRate: SlowMotionFrameRate,
        selectedVideoCodec: String,
        formatSelector: CameraFormatSelector
    ) -> PreparedTransition? {
        let startedAt = ProcessInfo.processInfo.systemUptime
        let trace = traceID(request.id)
        AppEventLog.deepEvent("PHYSICAL LENS PREPARATION START", category: .lens, traceID: trace, fields: [
            "requestedZoom": String(format: "%.3f", Double(request.requestedZoom)),
            "mode": request.mode.rawValue,
            "targetDeviceID": request.targetDeviceID,
            "currentDeviceID": currentDeviceID ?? "none"
        ])
        guard request.position == .back else {
            AppEventLog.guardRejected("preparePhysicalHandoff", reason: "not rear camera", traceID: trace)
            return nil
        }
        let physicalDevices = devices.filter { !$0.isVirtualDevice }
        guard let device = physicalDevices.first(where: { $0.uniqueID == request.targetDeviceID }) else {
            AppEventLog.guardRejected("preparePhysicalHandoff", reason: "target physical device not found", traceID: trace,
                                      fields: ["physicalDevices": physicalDevices.map(\.localizedName).joined(separator: ",")])
            return nil
        }

        let selectedFormat: AVCaptureDevice.Format?
        let frameRate: Double
        switch request.mode {
        case .video:
            guard request.videoResolution == selectedResolution,
                  request.videoFrameRate == selectedFrameRate,
                  request.codec == selectedVideoCodec else { return nil }
            selectedFormat = formatSelector.preferredRecordingFormat(
                for: device,
                resolution: request.videoResolution,
                rate: request.videoFrameRate
            )
            frameRate = Double(request.videoFrameRate.rawValue)
        case .sloMo:
            guard request.slowMotionResolution == selectedSlowMotionResolution,
                  request.slowMotionFrameRate == selectedSlowMotionFrameRate,
                  request.codec == selectedVideoCodec else { return nil }
            selectedFormat = formatSelector.bestSlowMotionFormat(
                for: device,
                resolution: request.slowMotionResolution,
                frameRate: request.slowMotionFrameRate
            )
            frameRate = Double(request.slowMotionFrameRate.rawValue)
        case .photo:
            return nil
        }
        guard let selectedFormat else {
            AppEventLog.guardRejected("preparePhysicalHandoff", reason: "no matching target format", traceID: trace,
                                      fields: ["device": device.localizedName])
            return nil
        }

        var replacementInput: AVCaptureDeviceInput?
        if currentDeviceID != device.uniqueID {
            do {
                let inputStart = ProcessInfo.processInfo.systemUptime
                replacementInput = try AVCaptureDeviceInput(device: device)
                AppEventLog.deepEvent("PHYSICAL LENS INPUT PREPARED", category: .lens, traceID: trace,
                                      fields: ["durationMs": String(format: "%.2f", (ProcessInfo.processInfo.systemUptime - inputStart) * 1000)])
            } catch {
                AppEventLog.log(error: error, prefix: "PHYSICAL LENS INPUT PREPARATION FAILED", category: .lens, traceID: trace)
                return nil
            }
        }

        let dimensions = CMVideoFormatDescriptionGetDimensions(selectedFormat.formatDescription)
        AppEventLog.deepEvent("PHYSICAL LENS PREPARATION COMPLETE", category: .lens, traceID: trace, fields: [
            "device": device.localizedName,
            "format": "\(dimensions.width)x\(dimensions.height)@\(String(format: "%.1f", frameRate))",
            "replacementInput": String(replacementInput != nil),
            "durationMs": String(format: "%.2f", (ProcessInfo.processInfo.systemUptime - startedAt) * 1000)
        ])
        return PreparedTransition(
            request: request,
            device: device,
            format: selectedFormat,
            frameRate: frameRate,
            replacementInput: replacementInput
        )
    }

    func beginVirtualHandoff(
        _ request: Request,
        device: AVCaptureDevice,
        initialValidate: @escaping (Request, AVCaptureDevice) -> Bool,
        delayedValidate: @escaping (Request, AVCaptureDevice) -> Bool,
        applyZoom: @escaping (Request, AVCaptureDevice) -> Bool,
        onFailure: @escaping () -> Void
    ) {
        let trace = traceID(request.id)
        AppEventLog.deepEvent("VIRTUAL LENS HANDOFF REQUEST", category: .lens, traceID: trace, fields: [
            "device": device.localizedName,
            "requestedZoom": String(format: "%.3f", Double(request.requestedZoom)),
            "deviceZoomBefore": String(format: "%.3f", Double(device.videoZoomFactor))
        ])
        guard device.uniqueID == request.targetDeviceID else {
            AppEventLog.guardRejected("beginVirtualHandoff", reason: "device ID changed", traceID: trace,
                                      fields: ["actualDeviceID": device.uniqueID, "targetDeviceID": request.targetDeviceID])
            return
        }
        guard initialValidate(request, device) else {
            AppEventLog.guardRejected("beginVirtualHandoff", reason: "initial validation failed", traceID: trace)
            return
        }

        beginCover(for: request.id)

        // Let the blur cover become visible first, then move the virtual device's zoom directly to
        // the requested value. AVFoundation keeps the same input/session and performs the constituent
        // camera handoff internally, which is the fast path used by its virtual camera architecture.
        sessionQueue.asyncAfter(deadline: .now() + 0.035) { [weak self, weak device] in
            guard let self, let device else { return }
            guard self.isActive(request.id) else {
                AppEventLog.guardRejected("virtual lens delayed apply", reason: "transition no longer active", traceID: trace)
                return
            }
            guard self.zoomRequests.isLatest(request.id) else { return }
            guard delayedValidate(request, device) else {
                AppEventLog.guardRejected("virtual lens delayed apply", reason: "delayed validation failed", traceID: trace)
                return
            }
            AppEventLog.deepEvent("VIRTUAL LENS APPLY BEGIN", category: .lens, traceID: trace,
                                  fields: ["deviceZoomBefore": String(format: "%.3f", Double(device.videoZoomFactor))])

            guard applyZoom(request, device) else {
                AppEventLog.event("VIRTUAL LENS APPLY FAILED", category: .lens, level: .error, traceID: trace)
                self.finish(request.id, revealDelay: 0)
                onFailure()
                return
            }

            guard self.isActive(request.id), self.zoomRequests.isLatest(request.id) else { return }
            AppEventLog.deepEvent("VIRTUAL LENS APPLY READBACK", category: .lens, traceID: trace, fields: [
                "device": device.localizedName,
                "deviceZoomAfter": String(format: "%.3f", Double(device.videoZoomFactor)),
                "requestedDisplayedZoom": String(format: "%.3f", Double(request.requestedZoom))
            ])

            // Keep the blur over the short optical/ISP constituent change. No format/input rebuild
            // happens here, so this stays close to the system camera's fast switch behavior.
            self.finish(request.id, revealDelay: 0.04)
        }
    }

    func beginPhysicalHandoff(
        _ request: Request,
        devices: [AVCaptureDevice],
        currentDeviceID: String?,
        selectedResolution: VideoResolution,
        selectedFrameRate: VideoFrameRate,
        selectedSlowMotionResolution: VideoResolution,
        selectedSlowMotionFrameRate: SlowMotionFrameRate,
        selectedVideoCodec: String,
        formatSelector: CameraFormatSelector,
        applyPrepared: @escaping (PreparedTransition) -> Bool,
        recoverAfterFailedApply: @escaping (Request) -> Void,
        onPreparationFailure: @escaping () -> Void,
        onApplyFailure: @escaping () -> Void
    ) {
        let trace = traceID(request.id)
        AppEventLog.deepEvent("PHYSICAL LENS HANDOFF REQUEST", category: .lens, traceID: trace, fields: [
            "requestedZoom": String(format: "%.3f", Double(request.requestedZoom)),
            "targetDeviceID": request.targetDeviceID,
            "currentDeviceID": currentDeviceID ?? "none",
            "mode": request.mode.rawValue
        ])
        // Do the format lookup and AVCaptureDeviceInput creation while the old preview is still
        // fully live. The visible transition then contains only the unavoidable hardware commit.
        guard let prepared = preparePhysicalHandoff(
            request,
            devices: devices,
            currentDeviceID: currentDeviceID,
            selectedResolution: selectedResolution,
            selectedFrameRate: selectedFrameRate,
            selectedSlowMotionResolution: selectedSlowMotionResolution,
            selectedSlowMotionFrameRate: selectedSlowMotionFrameRate,
            selectedVideoCodec: selectedVideoCodec,
            formatSelector: formatSelector
        ) else {
            AppEventLog.event("PHYSICAL LENS PREPARATION FAILED", category: .lens, level: .warning, traceID: trace)
            onPreparationFailure()
            return
        }

        beginCover(for: request.id)

        // The PreviewView blur animates in during this short lead-in. Unlike the old generic path,
        // expensive capability scans/input creation have already finished before the cover appears.
        sessionQueue.asyncAfter(deadline: .now() + 0.035) { [weak self] in
            guard let self else { return }
            guard self.isActive(request.id) else {
                // A newer zoom request owns the cover now. This is the expected cancellation path
                // during a fast drag, not a failed hardware apply; keep it in Extreme trace data
                // without inflating the warning count or presenting a false failure.
                AppEventLog.deepEvent("PHYSICAL LENS APPLY SUPERSEDED", category: .lens, traceID: trace,
                                      fields: ["reason": "transition no longer active"])
                return
            }
            guard self.zoomRequests.isLatest(request.id) else { return }

            let applyStart = ProcessInfo.processInfo.systemUptime
            AppEventLog.deepEvent("PHYSICAL LENS HARDWARE COMMIT BEGIN", category: .lens, traceID: trace,
                                  fields: ["targetDevice": prepared.device.localizedName])
            let applied = applyPrepared(prepared)
            AppEventLog.deepEvent("PHYSICAL LENS HARDWARE COMMIT END", category: .lens, traceID: trace, fields: [
                "applied": String(applied),
                "durationMs": String(format: "%.2f", (ProcessInfo.processInfo.systemUptime - applyStart) * 1000),
                "deviceZoomReadback": String(format: "%.3f", Double(prepared.device.videoZoomFactor))
            ])
            if !applied {
                // A zoom gesture can produce a newer request while 4K60 is blocked inside
                // commitConfiguration(). That makes this request stale without meaning the camera
                // transaction failed. Keep the existing cover alive and let the newer queued zoom
                // request take ownership instead of showing a false transition error.
                if !self.isActive(request.id) || !self.zoomRequests.isLatest(request.id) {
                    return
                }

                AppEventLog.event("PHYSICAL LENS APPLY FAILED", category: .lens, level: .error, traceID: trace)
                recoverAfterFailedApply(request)
                self.finish(request.id, revealDelay: 0)
                onApplyFailure()
                return
            }

            guard self.isActive(request.id) else { return }

            // The hardware switch itself succeeded. If another zoom request arrived while the slow
            // 4K60 commit was in progress, do not reveal the old target or call it a failure. The
            // newer request is already queued on sessionQueue and will apply its final zoom/lens
            // behind this same cover before it becomes responsible for the reveal.
            guard self.zoomRequests.isLatest(request.id) else { return }

            // Keep the cover through the first part of the new stream settling. PreviewView also
            // waits for the preview layer to be rendering, but AVCaptureVideoPreviewLayer.isPreviewing
            // can remain true across an input rebuild, so a tiny post-commit hold prevents the cover
            // from disappearing on a stale pre-switch preview state.
            self.finish(request.id, revealDelay: 0.04)
        }
    }

    func finish(_ requestID: UInt64, revealDelay: Double) {
        let trace = traceID(requestID)
        AppEventLog.deepEvent("LENS COVER REVEAL SCHEDULED", category: .lens, traceID: trace,
                              fields: ["delayMs": String(format: "%.1f", revealDelay * 1000)])
        sessionQueue.asyncAfter(deadline: .now() + revealDelay) { [weak self] in
            guard let self,
                  self.activeRequestID == requestID,
                  self.zoomRequests.isLatest(requestID) else { return }
            self.activeRequestID = nil
            let total = self.activeTraceStart.map { (ProcessInfo.processInfo.systemUptime - $0) * 1000 }
            self.activeTraceStart = nil
            self.onTransitioningChanged(false)
            AppEventLog.deepEvent("LENS TRANSITION FINISHED", category: .lens, traceID: trace,
                                  fields: ["totalMs": total.map { String(format: "%.2f", $0) } ?? "unknown"])
        }
    }

    func cancel() {
        guard let requestID = activeRequestID else { return }
        activeRequestID = nil
        activeTraceStart = nil
        onTransitioningChanged(false)
        AppEventLog.deepEvent("LENS TRANSITION CANCELED", category: .lens, traceID: traceID(requestID))
    }

    private func beginCover(for requestID: UInt64) {
        let previous = activeRequestID
        activeRequestID = requestID
        activeTraceStart = ProcessInfo.processInfo.systemUptime
        AppEventLog.deepEvent("LENS COVER BEGIN", category: .lens, traceID: traceID(requestID), fields: [
            "previousRequest": previous.map(String.init) ?? "none"
        ])
        if zoomRequests.isLatest(requestID) {
            onTransitioningChanged(true)
        }
    }
}
