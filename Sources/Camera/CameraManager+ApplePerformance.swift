import AVFoundation
import Foundation

// MARK: - CameraManager: Apple-native capture performance, readiness, and resource monitoring.

extension CameraManager {
    func configureApplePhotoPipeline() {
        guard AppleCameraFeatureFlags.responsivePhotoPipelineV2 else { return }

        // Keep deferred Photo Library delivery off: LowPolyCam needs immediate photo bytes for its
        // aspect/megapixel processing and validation pipeline.
        if photoOutput.isAutoDeferredPhotoDeliverySupported,
           photoOutput.isAutoDeferredPhotoDeliveryEnabled {
            photoOutput.isAutoDeferredPhotoDeliveryEnabled = false
        }

        // Apple requires Zero Shutter Lag for responsive overlapping captures. These support
        // values can change when the active device/format changes, so keep the enabled state
        // synchronized whenever LowPolyCam commits a real capture configuration.
        let zeroShutterLagEnabled = photoOutput.isZeroShutterLagSupported
        if photoOutput.isZeroShutterLagEnabled != zeroShutterLagEnabled {
            photoOutput.isZeroShutterLagEnabled = zeroShutterLagEnabled
        }

        let responsiveEnabled = zeroShutterLagEnabled && photoOutput.isResponsiveCaptureSupported
        if photoOutput.isResponsiveCaptureEnabled != responsiveEnabled {
            photoOutput.isResponsiveCaptureEnabled = responsiveEnabled
        }

        let fastCaptureEnabled = photoOutput.isFastCapturePrioritizationSupported &&
            AppleCameraFeatureFlags.fastCapturePrioritization
        if photoOutput.isFastCapturePrioritizationEnabled != fastCaptureEnabled {
            photoOutput.isFastCapturePrioritizationEnabled = fastCaptureEnabled
        }

        AppEventLog.event("APPLE PHOTO PIPELINE CONFIGURED", category: .photo, fields: [
            "zslSupported": String(photoOutput.isZeroShutterLagSupported),
            "zslEnabled": String(photoOutput.isZeroShutterLagEnabled),
            "responsiveSupported": String(photoOutput.isResponsiveCaptureSupported),
            "responsiveEnabled": String(photoOutput.isResponsiveCaptureEnabled),
            "fastCaptureSupported": String(photoOutput.isFastCapturePrioritizationSupported),
            "fastCaptureEnabled": String(photoOutput.isFastCapturePrioritizationEnabled),
            "autoDeferredDelivery": String(photoOutput.isAutoDeferredPhotoDeliveryEnabled)
        ])
    }

    func prepareCurrentPhotoSettings(reason: String) {
        guard AppleCameraFeatureFlags.responsivePhotoPipelineV2,
              session.outputs.contains(where: { $0 === photoOutput }) else { return }

        let dimensions = photoOutput.maxPhotoDimensions
        guard dimensions.width > 0, dimensions.height > 0 else { return }

        let useHEIC = photoFileFormat == "HEIC" && photoOutput.availablePhotoCodecTypes.contains(.hevc)
        let appliedFlash = resolvedPhotoFlashMode()
        let signature = [
            useHEIC ? "HEIC" : "JPEG",
            "\(dimensions.width)x\(dimensions.height)",
            "flash=\(appliedFlash.rawValue)",
            "camera=\(cameraPosition.rawValue)"
        ].joined(separator: "|")
        guard signature != lastPreparedPhotoSignature else { return }

        func makeSettings(priority: AVCapturePhotoOutput.QualityPrioritization) -> AVCapturePhotoSettings {
            let settings = useHEIC
                ? AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
                : AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
            settings.flashMode = appliedFlash
            settings.photoQualityPrioritization = priority
            settings.maxPhotoDimensions = dimensions
            return settings
        }

        // Prepare both paths LowPolyCam actually uses: balanced for normal photos and speed when
        // AE is locked. MP/aspect changes happen after capture, so they do not need extra camera
        // buffer allocations here.
        let prepared = [makeSettings(priority: .balanced), makeSettings(priority: .speed)]
        photoPreparationGeneration &+= 1
        let generation = photoPreparationGeneration
        lastPreparedPhotoSignature = signature
        photoOutput.setPreparedPhotoSettingsArray(prepared) { [weak self] preparedOK, error in
            guard let self else { return }
            self.sessionQueue.async {
                guard generation == self.photoPreparationGeneration else { return }
                if let error {
                    AppEventLog.log(error: error, prefix: "PHOTO SETTINGS PREPARATION", category: .photo)
                }
                AppEventLog.event("PHOTO SETTINGS PREPARED", category: .photo,
                                  level: preparedOK ? .info : .warning, fields: [
                    "success": String(preparedOK),
                    "reason": reason,
                    "signature": signature,
                    "count": String(prepared.count)
                ])
                if !preparedOK {
                    // Allow a later format/camera change to retry instead of treating the failed
                    // allocation as permanently prepared.
                    self.lastPreparedPhotoSignature = nil
                }
            }
        }
    }

    func handlePhotoCaptureReadinessChanged(_ readiness: AVCapturePhotoOutput.CaptureReadiness) {
        AppEventLog.deepEvent("PHOTO CAPTURE READINESS", category: .photo, fields: [
            "state": photoCaptureReadinessLabel(readiness),
            "pendingSingle": String(pendingSinglePhotoCapture),
            "burstRemaining": String(burstRemaining),
            "inFlight": String(inFlightPhotoCaptureIDs.count)
        ])
        guard readiness == .ready else { return }
        pumpPendingPhotoCaptures()
    }

    func photoCaptureReadinessLabel(_ readiness: AVCapturePhotoOutput.CaptureReadiness) -> String {
        switch readiness {
        case .ready: return "ready"
        case .sessionNotRunning: return "sessionNotRunning"
        case .notReadyMomentarily: return "notReadyMomentarily"
        case .notReadyWaitingForCapture: return "notReadyWaitingForCapture"
        case .notReadyWaitingForProcessing: return "notReadyWaitingForProcessing"
        @unknown default: return "unknown(\(readiness.rawValue))"
        }
    }

    func installActiveDeviceObservers(for device: AVCaptureDevice) {
        activePrimaryConstituentObservation?.invalidate()
        systemPressureObservation?.invalidate()
        activePrimaryConstituentObservation = nil
        systemPressureObservation = nil

        let deviceID = device.uniqueID
        systemPressureObservation = device.observe(\.systemPressureState, options: [.initial, .new]) { [weak self, weak device] _, _ in
            guard let self, let device else { return }
            let state = device.systemPressureState
            self.sessionQueue.async { [weak self, weak device] in
                guard let self, let device,
                      self.videoInput?.device.uniqueID == deviceID else { return }
                self.handleSystemPressureState(state, device: device)
            }
        }

        guard device.isVirtualDevice else { return }
        activePrimaryConstituentObservation = device.observe(\.activePrimaryConstituent, options: [.initial, .new]) { [weak self, weak device] _, _ in
            guard let self, let device else { return }
            self.sessionQueue.async { [weak self, weak device] in
                guard let self, let device,
                      self.videoInput?.device.uniqueID == deviceID else { return }
                let constituent = device.activePrimaryConstituent
                let switchFactors = device.virtualDeviceSwitchOverVideoZoomFactors
                    .map { String(format: "%.3f", $0.doubleValue) }
                    .joined(separator: ",")
                AppEventLog.event("APPLE VIRTUAL CAMERA CONSTITUENT", category: .device, fields: [
                    "virtualDevice": device.localizedName,
                    "activeConstituent": constituent?.localizedName ?? "none",
                    "rawZoom": String(format: "%.3f", Double(device.videoZoomFactor)),
                    "displayMultiplier": String(format: "%.3f", Double(device.displayVideoZoomFactorMultiplier)),
                    "switchFactors": switchFactors
                ])
                let lensLabel = self.lensDisplayLabel(for: device)
                self.publish {
                    if self.activeLensLabel != lensLabel {
                        self.activeLensLabel = lensLabel
                    }
                }
            }
        }
    }

    func handleSystemPressureState(_ state: AVCaptureDevice.SystemPressureState, device: AVCaptureDevice) {
        let level = state.level
        AppEventLog.event("CAMERA SYSTEM PRESSURE", category: .performance,
                          level: (level == .serious || level == .critical || level == .shutdown) ? .warning : .info,
                          fields: [
            "level": systemPressureLabel(level),
            "device": device.localizedName,
            "liveMetricsAttached": String(liveMetricsOutputIsAttached()),
            "recording": String(movieOutput.isRecording || recordingState.requestsRecording)
        ])

        if level == .nominal || level == .fair {
            let wasSuppressed = liveMetricsSuppressedBySystemPressure
            liveMetricsSuppressedBySystemPressure = false
            if wasSuppressed, !liveMetricsSuppressedByHardwareCost, postPreviewOutputsEnabled, !movieOutput.isRecording {
                refreshLiveMetrics()
            }
            return
        }

        guard level == .serious || level == .critical || level == .shutdown else { return }
        liveMetricsSuppressedBySystemPressure = true
        guard liveMetricsOutputIsAttached() else { return }

        // Preserve the user's requested recording quality. Shed optional real-time diagnostics
        // first; never silently downgrade resolution/FPS. If recording is already active, avoid a
        // graph mutation mid-file and disable the connection. Before recording starts, remove the
        // optional output so it actually releases capture resources.
        if movieOutput.isRecording {
            setLiveMetricsConnectionEnabled(false)
            stopLiveMetrics()
            return
        }

        session.beginConfiguration()
        stopLiveMetrics()
        session.removeOutput(liveMetrics.output)
        session.commitConfiguration()
        publish {
            if self.liveMetricsAvailable { self.liveMetricsAvailable = false }
        }
        AppEventLog.event("OPTIONAL LIVE METRICS REMOVED FOR SYSTEM PRESSURE", category: .performance, level: .warning)
    }

    func systemPressureLabel(_ level: AVCaptureDevice.SystemPressureState.Level) -> String {
        if level == .nominal { return "nominal" }
        if level == .fair { return "fair" }
        if level == .serious { return "serious" }
        if level == .critical { return "critical" }
        if level == .shutdown { return "shutdown" }
        return "unknown"
    }

    func schedulePostPreviewOutputEnableFallback(reason: String) {
        // Automatic Deferred Start normally gives us a precise "all deferred outputs ready"
        // callback. Keep a longer fallback only for unusual devices/session states where that
        // callback never arrives; this avoids racing optional data outputs against first preview.
        let deferredStartExpected =
            (photoOutput.isDeferredStartSupported && photoOutput.isDeferredStartEnabled) ||
            (movieOutput.isDeferredStartSupported && movieOutput.isDeferredStartEnabled)
        let delay: DispatchTimeInterval = deferredStartExpected ? .milliseconds(1000) : .milliseconds(200)
        sessionQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.enablePostPreviewOutputsIfNeeded(reason: reason)
        }
    }

    func enablePostPreviewOutputsIfNeeded(reason: String) {
        guard !postPreviewOutputsEnabled else { return }
        postPreviewOutputsEnabled = true
        AppEventLog.event("POST-PREVIEW CAMERA WORK ENABLED", category: .performance, fields: ["reason": reason])
        configureAudioMeterOutput()
        refreshLiveMetrics()
        prepareCurrentPhotoSettings(reason: "post-preview")
        enforceCaptureHardwareBudget(reason: "post-preview")
    }

    func enforceCaptureHardwareBudget(reason: String) {
        guard AppleCameraFeatureFlags.captureResourceManagementV2 else { return }
        let cost = session.hardwareCost
        AppEventLog.deepEvent("CAPTURE HARDWARE COST", category: .performance, fields: [
            "cost": String(format: "%.3f", cost),
            "reason": reason,
            "liveMetricsAttached": String(liveMetricsOutputIsAttached())
        ])
        guard cost > 1.0, liveMetricsOutputIsAttached() else { return }
        liveMetricsSuppressedByHardwareCost = true

        // A graph above Apple's hardware budget cannot run reliably. Live Metrics is optional, so
        // remove it before touching user-selected capture quality. Avoid mutating the graph only
        // when a movie file is already actively recording.
        if movieOutput.isRecording {
            setLiveMetricsConnectionEnabled(false)
            stopLiveMetrics()
            AppEventLog.event("CAPTURE HARDWARE COST ABOVE BUDGET; LIVE METRICS DISABLED", category: .performance, level: .warning,
                              fields: ["cost": String(format: "%.3f", cost)])
            return
        }

        session.beginConfiguration()
        stopLiveMetrics()
        session.removeOutput(liveMetrics.output)
        session.commitConfiguration()
        publish {
            if self.liveMetricsAvailable { self.liveMetricsAvailable = false }
        }
        AppEventLog.event("CAPTURE HARDWARE COST ABOVE BUDGET; LIVE METRICS REMOVED", category: .performance, level: .warning,
                          fields: ["before": String(format: "%.3f", cost), "after": String(format: "%.3f", session.hardwareCost)])
    }

    func applyVideoResourceFrameRateOverride(
        _ frameRate: Double?,
        to input: AVCaptureDeviceInput,
        traceID: String? = nil
    ) {
        guard AppleCameraFeatureFlags.captureResourceManagementV2 else { return }
        let desired: CMTime
        if let frameRate, frameRate > 0 {
            desired = CMTimeMakeWithSeconds(1.0 / frameRate, preferredTimescale: 60_000)
        } else {
            desired = .invalid
        }
        input.videoMinFrameDurationOverride = desired
        AppEventLog.deepEvent("VIDEO RESOURCE FPS OVERRIDE", category: .performance, traceID: traceID, fields: [
            "device": input.device.localizedName,
            "fps": frameRate.map { String(format: "%.2f", $0) } ?? "default"
        ])
    }
}

extension CameraManager: AVCaptureSessionDeferredStartDelegate {
    func sessionWillRunDeferredStart(_ session: AVCaptureSession) {
        AppEventLog.event("DEFERRED START WILL RUN", category: .performance)
    }

    func sessionDidRunDeferredStart(_ session: AVCaptureSession) {
        AppEventLog.event("DEFERRED START FINISHED", category: .performance)
        enablePostPreviewOutputsIfNeeded(reason: "deferred start finished")
    }
}
