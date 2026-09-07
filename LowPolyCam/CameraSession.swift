//
//  CameraSession.swift
//  LowPolyCam
//
//  Updated for iOS 27 / Xcode 27 / Swift 6.4.
//  Swift 6 complete concurrency · Observation · Liquid Glass · RotationCoordinator
//

import AVFoundation
import UIKit
import Photos
import MediaPlayer
import CoreMotion
import AudioToolbox
import ImageIO

extension CameraRecorder {

    // MARK: Session setup

    func configureSession() {
        DebugLog.write("configureSession() start position=\(position) mode=\(settings.cameraMode)")
        session.beginConfiguration()
        session.sessionPreset = .inputPriority

        if let device = Self.camera(at: position, mode: settings.cameraMode, preferPhysical: wantsPhysicalWideLens),
           let input = try? AVCaptureDeviceInput(device: device),
           session.canAddInput(input) {
            session.addInput(input)
            cameraInput = input
            DebugLog.write("configureSession() camera input added: \(device.localizedName)")
        } else {
            DebugLog.write("❌ configureSession() failed to add camera input for position=\(position) mode=\(settings.cameraMode)")
        }

        // Idle delegates are detached, so this is mostly a defensive default.
        // Recording flips it off and uses a small bounded application queue so
        // a momentary encoder pause doesn't silently turn 240fps into ~210fps.
        videoOutput.alwaysDiscardsLateVideoFrames = RecordingLimits.discardsLateFrames(isRecording: false)
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
        // Delegates stay nil while idle. They are attached only for the
        // duration of a recording (see startRecording / stopRecording) so
        // the system does not deliver every preview frame into the process
        // when nothing is being written — major idle-heat reduction.
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }

        if session.canAddOutput(audioOutput) { session.addOutput(audioOutput) }

        if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }

        // Photo dimensions belong to the active camera format. Configure them
        // while the capture graph is still being assembled; changing them after
        // a live 4K60 format swap can make AVFoundation raise an exception.
        configurePhotoOutput(for: cameraInput?.device)
        session.commitConfiguration()

        configureVideoConnection()
        refreshCapabilitiesThenApplyFormat()
        refreshTorchState()
        resetFocusAndExposureToAuto()
        syncMicInput()
        DebugLog.write("configureSession() done")
    }

    // MARK: Photo Output Configuration

    func configurePhotoOutput(for device: AVCaptureDevice? = nil) {
        guard let device = device ?? cameraInput?.device else { return }

        photoOutput.maxPhotoQualityPrioritization = .quality
        if let largest = device.activeFormat.supportedMaxPhotoDimensions.max(by: {
            Int($0.width) * Int($0.height) < Int($1.width) * Int($1.height)
        }) {
            let current = photoOutput.maxPhotoDimensions
            if current.width != largest.width || current.height != largest.height {
                photoOutput.maxPhotoDimensions = largest
            }
        }
    }

    func configureVideoConnection() {
        guard let c = videoOutput.connection(with: .video) else { return }
        // iOS 17+: videoOrientation is deprecated — RotationCoordinator owns preview/output angles.
        if c.isVideoMirroringSupported {
            c.automaticallyAdjustsVideoMirroring = false
            c.isVideoMirrored = false
        }
        applyStabilization(to: c)
    }

    func applyStabilization(to connection: AVCaptureConnection? = nil, forceRecording: Bool? = nil) {
        guard let c = connection ?? videoOutput.connection(with: .video) else { return }
        let supported = c.isVideoStabilizationSupported
        if supported {
            // Keep stabilisation ON whenever the user has it enabled (Video /
            // Slow-Mo only), not only while recording. Toggling it at Record
            // start/stop crops the FOV and looks like a flash/flicker — stock
            // Camera does not do that. Still force off at 4K (A10 can't hold
            // 30 fps with stab) and in Photo mode (still path is separate).
            _ = forceRecording // retained for call-site compatibility
            // Stab at 120/240fps is not viable on A10 and can break the writer.
            let wantStab = settings.stabilization
                && settings.cameraMode != .photo
                && settings.cameraMode != .slowMo
            c.preferredVideoStabilizationMode = wantStab ? .auto : .off
        }
        Task { @MainActor in self.stabilizationSupported = supported }
    }

    func updateStabilization() {
        sessionQueue.async { self.applyStabilization() }
    }

    func ensureCorrectCameraDevice(for mode: CameraMode) {
        let targetDevice: AVCaptureDevice?
        if mode == .slowMo, position == .back {
            let requestedZoom = zoomFactor > 0 ? zoomFactor : 1
            targetDevice = physicalDevice(for: requestedZoom)
                ?? Self.camera(at: position, mode: mode, preferPhysical: true)
        } else if mode == .video, position == .back, normalVideoNeedsPhysicalRoute(), !isRecording {
            targetDevice = physicalDevice(for: zoomFactor > 0 ? zoomFactor : 1)
                ?? Self.camera(at: position, mode: mode, preferPhysical: true)
        } else {
            targetDevice = Self.camera(at: position, mode: mode, preferPhysical: wantsPhysicalWideLens)
        }
        guard let targetDevice else { return }
        switchCameraInput(to: targetDevice)
    }

    /// Slow-Mo needs explicit physical-lens routing on iPhone 11. Its virtual
    /// dual-wide device does not expose the high-frame-rate formats, so 0.5x
    /// cannot be reached by changing `videoZoomFactor` alone.
    func slowMoPhysicalDevice(for displayedZoom: CGFloat, resetToWide: Bool = false) -> AVCaptureDevice? {
        physicalDevice(for: displayedZoom, resetToWide: resetToWide)
    }

    /// Physical routing is required only when a rear virtual device cannot
    /// expose the selected high-FPS format. Route both 0.5x and 1x, instead of
    /// always falling back to physical wide and silently deleting 0.5x.
    func physicalDevice(for displayedZoom: CGFloat, resetToWide: Bool = false) -> AVCaptureDevice? {
        guard position == .back else {
            return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
        }
        let type: AVCaptureDevice.DeviceType = ZoomPolicy.useUltraWide(
            zoom: Double(displayedZoom),
            currentlyUltraWide: cameraInput?.device.deviceType == .builtInUltraWideCamera,
            reset: resetToWide)
            ? .builtInUltraWideCamera : .builtInWideAngleCamera
        guard let device = AVCaptureDevice.default(type, for: .video, position: .back) else { return nil }
        let dims = settings.cameraMode == .slowMo
            ? settings.slowMoResolution.captureDimensions : settings.resolution.captureDimensions
        let fps = settings.cameraMode == .slowMo
            ? Double(settings.slowMoFrameRate.value) : Double(settings.frameRate.value)
        return CameraFormatSelector.bestVideoFormat(
            for: device, width: dims.w, height: dims.h, fps: fps
        ) == nil ? nil : device
    }

    func normalVideoNeedsPhysicalRoute() -> Bool {
        guard settings.cameraMode == .video, position == .back,
              let virtual = Self.virtualBackCamera() else { return false }
        let dims = settings.resolution.captureDimensions
        let fps = Double(settings.frameRate.value)
        guard CameraFormatSelector.bestVideoFormat(for: virtual, width: dims.w, height: dims.h, fps: fps) == nil else {
            return false
        }
        return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back).map {
            CameraFormatSelector.bestVideoFormat(for: $0, width: dims.w, height: dims.h, fps: fps) != nil
        } ?? false
    }

    func switchCameraInput(to targetDevice: AVCaptureDevice) {
        guard cameraInput?.device.uniqueID != targetDevice.uniqueID else { return }
        DebugLog.write("switchCameraInput() -> \(targetDevice.localizedName) mode=\(settings.cameraMode)")
        Task { @MainActor in self.volumeObserver?.ignoreTemporarily() }

        // Create and validate the replacement before removing the live input.
        // If input creation/configuration fails, preserving the old input keeps
        // the preview usable instead of leaving the session with no camera.
        guard let input = try? AVCaptureDeviceInput(device: targetDevice) else {
            DebugLog.write("❌ switchCameraInput() failed to create AVCaptureDeviceInput")
            Task { @MainActor in self.notice = "Could not switch camera" }
            return
        }

        session.beginConfiguration()
        let old = cameraInput
        if let old = old { session.removeInput(old) }
        if session.canAddInput(input) {
            session.addInput(input)
            cameraInput = input
            lastAppliedFormatKey = nil
            // The previous input may have left maxPhotoDimensions set to a
            // value the replacement lens cannot provide (notably 4K60 wide →
            // Photo dual-wide). Update it before committing the new graph.
            configurePhotoOutput(for: targetDevice)
        } else if let old = old, session.canAddInput(old) {
            // Restore the existing input if the replacement is rejected.
            session.addInput(old)
            configurePhotoOutput(for: old.device)
            DebugLog.write("❌ switchCameraInput() rejected new input, restored previous")
            Task { @MainActor in self.notice = "Could not switch camera" }
        } else {
            DebugLog.write("❌ switchCameraInput() rejected new input, no previous input to restore")
            Task { @MainActor in self.notice = "Could not switch camera" }
        }
        session.commitConfiguration()
        configureVideoConnection()
    }

    func syncMicInput() {
        if settings.recordAudio && AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            Task { [weak self] in
                _ = await AVCaptureDevice.requestAccess(for: .audio)
                self?.addOrRemoveMic()
            }
            return
        }
        addOrRemoveMic()
    }

    func addOrRemoveMic() {
        sessionQueue.async {
            Task { @MainActor in self.volumeObserver?.ignoreTemporarily() }
            let want = self.settings.recordAudio && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            if want, self.micInput == nil {
                guard let mic = AVCaptureDevice.default(for: .audio),
                      let input = try? AVCaptureDeviceInput(device: mic) else { return }
                self.session.beginConfiguration()
                if self.session.canAddInput(input) {
                    self.session.addInput(input)
                    self.micInput = input
                }
                self.session.commitConfiguration()
            } else if !want, let input = self.micInput {
                self.session.beginConfiguration()
                self.session.removeInput(input)
                self.session.commitConfiguration()
                self.micInput = nil
            }
        }
    }

    func flipCamera() {
        guard !isRecording, !isStartingRecording, !isSaving, !isCapturingPhoto,
              !isBursting, !isSwitchingMode, !isSwitchingCamera else { return }

        let beginFlip: () -> Void = {
            self.beginCameraFlipTransaction()
        }
        if Thread.isMainThread {
            beginFlip()
        } else {
            DispatchQueue.main.async(execute: beginFlip)
        }
    }

    private func beginCameraFlipTransaction() {
        volumeObserver?.stop()
        isSwitchingCamera = true
        setTorch(on: false)

        // Give the UI cover one short frame to become opaque before changing
        // the capture graph, preserving the previous visible timing.
        sessionQueue.asyncAfter(deadline: .now() + 0.10) {
            self.performCameraFlipTransaction()
        }
    }

    private func performCameraFlipTransaction() {
        let next: AVCaptureDevice.Position = (position == .back) ? .front : .back
        DebugLog.write("flipCamera() \(position) -> \(next) mode=\(settings.cameraMode)")

        guard let input = resolveCameraFlipInput(nextPosition: next) else {
            DebugLog.write("❌ flipCamera() could not resolve/create input for \(next)")
            finishCameraFlipUI()
            return
        }

        session.beginConfiguration()
        let oldInput = cameraInput
        if let oldInput { session.removeInput(oldInput) }

        if session.canAddInput(input) {
            session.addInput(input)
            cameraInput = input
            position = next
            configurePhotoOutput(for: input.device)
            lastAppliedFormatKey = nil
        } else if let oldInput, session.canAddInput(oldInput) {
            session.addInput(oldInput)
            DebugLog.write("❌ flipCamera() new input rejected, restored previous")
            Task { @MainActor in self.notice = "Could not switch camera" }
        } else {
            DebugLog.write("❌ flipCamera() new input rejected, no previous input to restore")
            Task { @MainActor in self.notice = "Could not switch camera" }
        }
        session.commitConfiguration()

        configureVideoConnection()
        refreshTorchState()
        refreshCapabilitiesThenApplyFormat(completion: finishCameraFlipUI)
        resetFocusAndExposureToAuto()
        DebugLog.write("flipCamera() done, position=\(position)")
    }

    private func resolveCameraFlipInput(nextPosition: AVCaptureDevice.Position) -> AVCaptureDeviceInput? {
        let requestedZoom = zoomFactor > 0 ? zoomFactor : 1
        let routePhysicalVideo = nextPosition == .back && settings.cameraMode == .video
            && Self.virtualBackCamera().map {
                CameraFormatSelector.bestVideoFormat(for: $0,
                    width: settings.resolution.captureDimensions.w,
                    height: settings.resolution.captureDimensions.h,
                    fps: Double(settings.frameRate.value)) == nil
            } == true

        let routedType: AVCaptureDevice.DeviceType = requestedZoom < 1
            ? .builtInUltraWideCamera : .builtInWideAngleCamera
        let routedCandidate = routePhysicalVideo
            ? AVCaptureDevice.default(routedType, for: .video, position: .back) : nil
        let routedDevice = routedCandidate.flatMap { candidate in
            CameraFormatSelector.bestVideoFormat(for: candidate,
                width: settings.resolution.captureDimensions.w,
                height: settings.resolution.captureDimensions.h,
                fps: Double(settings.frameRate.value)) == nil ? nil : candidate
        } ?? (routePhysicalVideo
            ? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
            : nil)

        guard let device = routedDevice ?? Self.camera(at: nextPosition,
                                                       mode: settings.cameraMode,
                                                       preferPhysical: wantsPhysicalWideLens) else {
            return nil
        }
        return try? AVCaptureDeviceInput(device: device)
    }

    private func finishCameraFlipUI() {
        Task { @MainActor in
            self.isFrontCamera = (self.position == .front)
            self.isSwitchingCamera = false
            self.settings.lastCameraPosition = CameraFacing(self.position)
            self.resumeVolumeMonitoring()
        }
    }

    static func camera(at position: AVCaptureDevice.Position, mode: CameraMode, preferPhysical: Bool = false) -> AVCaptureDevice? {
        if position == .back && !preferPhysical {
            let virtualTypes: [AVCaptureDevice.DeviceType] = [
                .builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera
            ]
            for type in virtualTypes {
                guard let device = AVCaptureDevice.default(type, for: .video, position: .back) else { continue }
                if mode == .slowMo && !supportsSlowMotion(device) { continue }
                return device
            }
        }
        return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
            ?? AVCaptureDevice.default(for: .video)
    }

    static func supportsSlowMotion(_ device: AVCaptureDevice) -> Bool {
        device.formats.contains { format in
            format.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= 119.0 }
        }
    }

    var wantsPhysicalWideForFrameRate: Bool {
        false
    }

    static func virtualBackCamera() -> AVCaptureDevice? {
        for type: AVCaptureDevice.DeviceType in [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera] {
            if let device = AVCaptureDevice.default(type, for: .video, position: .back) { return device }
        }
        return nil
    }

    var wantsPhysicalWideLens: Bool {
        wantsPhysicalWideForFrameRate
    }


}
