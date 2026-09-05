import AVFoundation
import Foundation
import Photos

final class CameraManager: NSObject, ObservableObject {
    enum CaptureMode: String, CaseIterable, Identifiable {
        case video = "VIDEO"
        case photo = "PHOTO"

        var id: String { rawValue }
    }

    enum CameraPosition {
        case back
        case front

        var avPosition: AVCaptureDevice.Position {
            self == .back ? .back : .front
        }
    }

    enum WhiteBalancePreset: String, CaseIterable, Identifiable {
        case auto = "Auto"
        case daylight = "Daylight"
        case cloudy = "Cloudy"
        case tungsten = "Tungsten"
        case fluorescent = "Fluorescent"

        var id: String { rawValue }

        var temperature: Float? {
            switch self {
            case .auto: return nil
            case .daylight: return 5_200
            case .cloudy: return 6_500
            case .tungsten: return 3_200
            case .fluorescent: return 4_000
            }
        }
    }

    @Published private(set) var isSessionRunning = false
    @Published private(set) var isRecording = false
    @Published private(set) var isCapturingPhoto = false
    @Published private(set) var captureMode: CaptureMode = .video
    @Published private(set) var isFocusExposureLocked = false
    @Published private(set) var exposureBias: Float = 0
    @Published private(set) var whiteBalancePreset: WhiteBalancePreset = .auto
    @Published private(set) var recordingDuration: TimeInterval = 0
    @Published private(set) var supportedResolutions: [VideoResolution] = []
    @Published private(set) var supportedFrameRates: [VideoFrameRate] = []
    @Published private(set) var cameraPosition: CameraPosition = .back
    @Published private(set) var torchAvailable = false
    @Published private(set) var isTorchOn = false
    @Published private(set) var minimumZoomFactor: CGFloat = 1
    @Published private(set) var maximumZoomFactor: CGFloat = 1
    @Published private(set) var zoomFactor: CGFloat = 1
    @Published private(set) var zoomLabel = "1×"
    @Published var statusMessage: String?

    @Published var selectedResolution: VideoResolution {
        didSet { UserDefaults.standard.set(selectedResolution.rawValue, forKey: Self.resolutionKey) }
    }
    @Published var selectedFrameRate: VideoFrameRate {
        didSet { UserDefaults.standard.set(selectedFrameRate.rawValue, forKey: Self.frameRateKey) }
    }

    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.swazi.lowpolycam.camera")
    private let movieOutput = AVCaptureMovieFileOutput()
    private let photoOutput = AVCapturePhotoOutput()
    private var videoInput: AVCaptureDeviceInput?
    private var durationTimer: Timer?
    private var recordingStartedAt: Date?
    private var requestedZoom: CGFloat = 1
    private var requestedExposureBias: Float = 0
    private var exposureDragStartBias: Float = 0
    private var pendingFocusLockWorkItem: DispatchWorkItem?
    private let zoomRequestLock = NSLock()
    private var latestZoomRequestID: UInt64 = 0

    private static let resolutionKey = "selectedVideoResolution"
    private static let frameRateKey = "selectedVideoFrameRate"

    override init() {
        let savedResolution = UserDefaults.standard.string(forKey: Self.resolutionKey)
        selectedResolution = VideoResolution(rawValue: savedResolution ?? "") ?? .p1080
        let savedFrameRate = UserDefaults.standard.integer(forKey: Self.frameRateKey)
        selectedFrameRate = VideoFrameRate(rawValue: savedFrameRate) ?? .fps30
        super.init()
    }

    func start() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.configureSessionIfNeeded()
            self.resetZoomToOne()
            guard self.session.isRunning == false else { return }
            self.session.startRunning()
            self.publish { self.isSessionRunning = true }
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
            self.publish { self.isSessionRunning = false }
        }
    }

    func appDidBecomeInactive() {
        // iOS turns the torch off when the app is no longer active. Reflect that immediately
        // so the UI never comes back showing a yellow torch button while the LED is off.
        publish { self.isTorchOn = false }
    }

    func appDidBecomeActive() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if !self.session.isRunning, self.videoInput != nil {
                self.session.startRunning()
                self.publish { self.isSessionRunning = true }
            }
            self.synchronizeTorchState()
        }
    }

    func toggleTorch() {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.videoInput?.device, device.hasTorch else { return }
            do {
                try device.lockForConfiguration()
                device.torchMode = device.torchMode == .on ? .off : .on
                let isOn = device.torchMode == .on
                device.unlockForConfiguration()
                self.publish { self.isTorchOn = isOn }
            } catch {
                self.showError("Couldn’t change the torch.")
            }
        }
    }

    func setZoomFactor(_ requestedFactor: CGFloat) {
        // Drag gestures can emit far more updates than camera hardware can apply. Give each
        // request an ID so stale queued updates are discarded instead of building up latency.
        let requestID = nextZoomRequestID()
        sessionQueue.async { [weak self] in
            guard let self, self.isLatestZoomRequest(requestID),
                  let currentDevice = self.videoInput?.device else { return }

            self.requestedZoom = requestedFactor
            if !currentDevice.isVirtualDevice {
                if self.movieOutput.isRecording {
                    if requestedFactor < 1 && currentDevice.deviceType != .builtInUltraWideCamera {
                        self.showError("Stop recording to switch to 0.5× at this quality.")
                    }
                } else if (requestedFactor < 1) != (currentDevice.deviceType == .builtInUltraWideCamera) {
                    self.applyActiveModeFormat()
                }
            }

            guard self.isLatestZoomRequest(requestID),
                  let device = self.videoInput?.device else { return }
            let factor = self.snappedZoomFactor(requestedFactor, for: device)
            do {
                try device.lockForConfiguration()
                let deviceFactor = self.deviceZoomFactor(for: factor, device: device)
                // Snap real lens positions immediately. Intermediate zoom values can still ramp.
                if abs(factor - 0.5) < 0.01 || abs(factor - 1.0) < 0.01 {
                    device.cancelVideoZoomRamp()
                    device.videoZoomFactor = deviceFactor
                } else {
                    device.ramp(toVideoZoomFactor: deviceFactor, withRate: 20)
                }
                device.unlockForConfiguration()
                self.publish {
                    self.zoomFactor = factor
                    self.zoomLabel = self.formattedZoomLabel(for: factor)
                }
            } catch {
                self.showError("Couldn’t change the zoom.")
            }
        }
    }

    private func nextZoomRequestID() -> UInt64 {
        zoomRequestLock.lock()
        defer { zoomRequestLock.unlock() }
        latestZoomRequestID &+= 1
        return latestZoomRequestID
    }

    private func isLatestZoomRequest(_ requestID: UInt64) -> Bool {
        zoomRequestLock.lock()
        defer { zoomRequestLock.unlock() }
        return requestID == latestZoomRequestID
    }

    func switchCamera() {
        guard !isRecording, !isCapturingPhoto else { return }
        cameraPosition = cameraPosition == .back ? .front : .back
        sessionQueue.async { [weak self] in self?.reconfigureCamera() }
    }

    func selectCaptureMode(_ mode: CaptureMode) {
        guard !isRecording, !isCapturingPhoto, captureMode != mode else { return }
        captureMode = mode
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.applyActiveModeFormat()
            self.resetFocusAndExposureState()
        }
    }

    func capturePhoto() {
        guard captureMode == .photo, !isRecording, !isCapturingPhoto else { return }
        isCapturingPhoto = true
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.beginPhotoCapture()
        }
    }

    func focusAndExpose(at point: CGPoint) {
        sessionQueue.async { [weak self] in
            self?.configureFocusAndExposure(at: point, lockAfterFocusing: false)
        }
    }

    func lockFocusAndExposure(at point: CGPoint) {
        sessionQueue.async { [weak self] in
            self?.configureFocusAndExposure(at: point, lockAfterFocusing: true)
        }
    }

    func beginExposureAdjustment() {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.videoInput?.device else { return }
            self.exposureDragStartBias = device.exposureTargetBias
        }
    }

    func adjustExposure(by deltaEV: Float) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.applyExposureBias(self.exposureDragStartBias + deltaEV)
        }
    }

    func setExposureBias(_ bias: Float) {
        sessionQueue.async { [weak self] in
            self?.applyExposureBias(bias)
        }
    }

    func selectWhiteBalancePreset(_ preset: WhiteBalancePreset) {
        sessionQueue.async { [weak self] in
            guard let self, let inputDevice = self.videoInput?.device else { return }

            let primaryDevice = self.primaryWhiteBalanceDevice(for: inputDevice)
            let primaryApplied = self.applyWhiteBalancePreset(preset, to: primaryDevice)

            // Pre-apply the same preset to the other physical lenses of a virtual camera so
            // crossing 0.5×/1× doesn't silently return the newly active lens to Auto WB.
            for device in self.whiteBalanceControlDevices(for: inputDevice)
                where device.uniqueID != primaryDevice.uniqueID {
                _ = self.applyWhiteBalancePreset(preset, to: device)
            }

            if primaryApplied {
                self.publish { self.whiteBalancePreset = preset }
            } else {
                self.showError("Couldn’t change white balance on this camera.")
            }
        }
    }

    func selectResolution(_ resolution: VideoResolution) {
        selectedResolution = resolution
        guard captureMode == .video else { return }
        sessionQueue.async { [weak self] in self?.applySelectedFormat() }
    }

    func selectFrameRate(_ frameRate: VideoFrameRate) {
        selectedFrameRate = frameRate
        guard captureMode == .video else { return }
        sessionQueue.async { [weak self] in self?.applySelectedFormat() }
    }

    func startOrStopRecording() {
        guard captureMode == .video else { return }
        if isRecording {
            sessionQueue.async { [weak self] in self?.movieOutput.stopRecording() }
        } else {
            sessionQueue.async { [weak self] in self?.beginRecording() }
        }
    }

    private func configureSessionIfNeeded() {
        guard videoInput == nil else { return }
        session.beginConfiguration()
        session.sessionPreset = .inputPriority
        defer { session.commitConfiguration() }

        guard addVideoInput(for: cameraPosition.avPosition) else { return }
        addAudioInput()
        guard session.canAddOutput(movieOutput) else {
            showError("Video recording is unavailable on this device.")
            return
        }
        session.addOutput(movieOutput)

        guard session.canAddOutput(photoOutput) else {
            showError("Photo capture is unavailable on this device.")
            return
        }
        photoOutput.maxPhotoQualityPrioritization = .quality
        session.addOutput(photoOutput)

        updateCapabilities()
        applyActiveModeFormat()
        resetFocusAndExposureState()
    }

    private func reconfigureCamera() {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        if let videoInput { session.removeInput(videoInput) }
        guard addVideoInput(for: cameraPosition.avPosition) else {
            cameraPosition = cameraPosition == .back ? .front : .back
            _ = addVideoInput(for: cameraPosition.avPosition)
            showError("That camera is unavailable.")
            return
        }
        updateCapabilities()
        applyActiveModeFormat()
        resetFocusAndExposureState()
    }

    @discardableResult
    private func addVideoInput(for position: AVCaptureDevice.Position) -> Bool {
        guard let device = cameraSupportingCurrentQuality(for: position) ?? preferredCamera(for: position) else {
            return false
        }
        return addVideoInput(device)
    }

    @discardableResult
    private func addVideoInput(_ device: AVCaptureDevice) -> Bool {
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else { return false }
            try device.lockForConfiguration()
            if device.isGeometricDistortionCorrectionSupported {
                device.isGeometricDistortionCorrectionEnabled = true
            }
            device.unlockForConfiguration()
            session.addInput(input)
            videoInput = input
            return true
        } catch {
            showError("Couldn’t access the camera.")
            return false
        }
    }

    private func replaceVideoInput(with device: AVCaptureDevice) -> Bool {
        guard let oldInput = videoInput else { return false }
        session.beginConfiguration()
        session.removeInput(oldInput)

        if addVideoInput(device) {
            session.commitConfiguration()
            return true
        }

        if session.canAddInput(oldInput) {
            session.addInput(oldInput)
            videoInput = oldInput
        }
        session.commitConfiguration()
        return false
    }

    private func addAudioInput() {
        guard let device = AVCaptureDevice.default(for: .audio) else { return }
        do {
            let input = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(input) { session.addInput(input) }
        } catch {
            showError("Couldn’t access the microphone.")
        }
    }

    private func updateCapabilities() {
        guard let device = videoInput?.device else { return }
        let devices = capabilityDevices(for: device.position)
        let supported = availableResolutions(for: devices)
        let selection = validSelection(for: devices, availableResolutions: supported)
        publish {
            self.supportedResolutions = supported
            self.torchAvailable = device.hasTorch
            self.isTorchOn = device.torchMode == .on
            self.minimumZoomFactor = self.minimumSupportedZoom(for: device)
            self.maximumZoomFactor = self.maximumSupportedZoom(for: device)
            let displayedZoom = self.displayedZoomFactor(for: device.videoZoomFactor, device: device)
            self.zoomFactor = displayedZoom
            self.zoomLabel = self.formattedZoomLabel(for: displayedZoom)
            self.selectedResolution = selection.resolution
            self.selectedFrameRate = selection.frameRate
            self.supportedFrameRates = selection.supportedFrameRates
        }
    }

    private func preferredCamera(for position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        let deviceTypes: [AVCaptureDevice.DeviceType] = [
            .builtInTripleCamera,
            .builtInDualWideCamera,
            .builtInDualCamera,
            .builtInWideAngleCamera
        ]

        for type in deviceTypes {
            if let device = AVCaptureDevice.default(type, for: .video, position: position) {
                return device
            }
        }
        return nil
    }

    private func capabilityDevices(for position: AVCaptureDevice.Position) -> [AVCaptureDevice] {
        var devices: [AVCaptureDevice] = []
        if let preferred = preferredCamera(for: position) {
            devices.append(preferred)
        }
        if let wide = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
           devices.contains(where: { $0.uniqueID == wide.uniqueID }) == false {
            devices.append(wide)
        }
        if let ultra = AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: position) {
            devices.append(ultra)
        }
        return devices
    }

    private func cameraSupportingCurrentQuality(for position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        capabilityDevices(for: position).first { device in
            device.formats.contains { format($0, supports: selectedResolution, at: selectedFrameRate) }
        }
    }

    private func resetFocusAndExposureState() {
        pendingFocusLockWorkItem?.cancel()
        pendingFocusLockWorkItem = nil
        guard let device = videoInput?.device else { return }
        do {
            try device.lockForConfiguration()
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            let target = clampedExposureBias(requestedExposureBias, for: device)
            device.setExposureTargetBias(target, completionHandler: nil)
            device.unlockForConfiguration()
            publish {
                self.isFocusExposureLocked = false
                self.exposureBias = target
            }
            applyWhiteBalancePresetToCurrentCamera(whiteBalancePreset)
        } catch {
            showError("Couldn’t reset focus and exposure.")
        }
    }

    private func clampedExposureBias(_ bias: Float, for device: AVCaptureDevice) -> Float {
        let proToolsMinimum: Float = -2
        let proToolsMaximum: Float = 2
        return min(max(bias, max(device.minExposureTargetBias, proToolsMinimum)), min(device.maxExposureTargetBias, proToolsMaximum))
    }

    private func applyExposureBias(_ bias: Float) {
        guard let device = videoInput?.device else { return }
        let target = clampedExposureBias(bias, for: device)
        do {
            try device.lockForConfiguration()
            device.setExposureTargetBias(target, completionHandler: nil)
            device.unlockForConfiguration()
            requestedExposureBias = target
            publish { self.exposureBias = target }
        } catch {
            showError("Couldn’t adjust the exposure.")
        }
    }

    private func primaryWhiteBalanceDevice(for inputDevice: AVCaptureDevice) -> AVCaptureDevice {
        guard inputDevice.isVirtualDevice else { return inputDevice }

        if let active = inputDevice.activePrimaryConstituent {
            return active
        }

        let preferredType: AVCaptureDevice.DeviceType = requestedZoom < 1
            ? .builtInUltraWideCamera
            : .builtInWideAngleCamera
        return inputDevice.constituentDevices.first(where: { $0.deviceType == preferredType })
            ?? inputDevice.constituentDevices.first
            ?? inputDevice
    }

    private func whiteBalanceControlDevices(for inputDevice: AVCaptureDevice) -> [AVCaptureDevice] {
        guard inputDevice.isVirtualDevice, !inputDevice.constituentDevices.isEmpty else {
            return [inputDevice]
        }

        var devices = inputDevice.constituentDevices
        devices.append(inputDevice)
        return devices
    }

    private func applyWhiteBalancePresetToCurrentCamera(_ preset: WhiteBalancePreset) {
        guard let inputDevice = videoInput?.device else { return }
        for device in whiteBalanceControlDevices(for: inputDevice) {
            _ = applyWhiteBalancePreset(preset, to: device)
        }
    }

    @discardableResult
    private func applyWhiteBalancePreset(_ preset: WhiteBalancePreset, to device: AVCaptureDevice) -> Bool {
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }

            if preset == .auto {
                if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                    device.whiteBalanceMode = .continuousAutoWhiteBalance
                    return true
                }
                if device.isWhiteBalanceModeSupported(.autoWhiteBalance) {
                    device.whiteBalanceMode = .autoWhiteBalance
                    return true
                }
                return false
            }

            guard let temperature = preset.temperature,
                  device.isLockingWhiteBalanceWithCustomDeviceGainsSupported,
                  device.isWhiteBalanceModeSupported(.locked) else {
                return false
            }

            let values = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: temperature, tint: 0)
            var gains = device.deviceWhiteBalanceGains(for: values)
            let maximum = device.maxWhiteBalanceGain
            gains.redGain = min(max(gains.redGain, 1), maximum)
            gains.greenGain = min(max(gains.greenGain, 1), maximum)
            gains.blueGain = min(max(gains.blueGain, 1), maximum)
            device.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
            return true
        } catch {
            return false
        }
    }

    private func configureFocusAndExposure(at point: CGPoint, lockAfterFocusing: Bool) {
        guard let device = videoInput?.device else { return }
        pendingFocusLockWorkItem?.cancel()
        pendingFocusLockWorkItem = nil

        let clampedPoint = CGPoint(
            x: min(max(point.x, 0), 1),
            y: min(max(point.y, 0), 1)
        )

        do {
            try device.lockForConfiguration()

            if device.isFocusPointOfInterestSupported {
                device.focusPointOfInterest = clampedPoint
            }
            if device.isFocusModeSupported(.autoFocus) {
                device.focusMode = .autoFocus
            } else if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }

            if device.isExposurePointOfInterestSupported {
                device.exposurePointOfInterest = clampedPoint
            }
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            } else if device.isExposureModeSupported(.autoExpose) {
                device.exposureMode = .autoExpose
            }

            device.unlockForConfiguration()
            publish {
                self.isFocusExposureLocked = false
            }
        } catch {
            showError("Couldn’t set focus and exposure.")
            return
        }

        guard lockAfterFocusing else { return }

        let deviceID = device.uniqueID
        let workItem = DispatchWorkItem { [weak self, weak device] in
            guard let self, let device,
                  self.videoInput?.device.uniqueID == deviceID else { return }
            do {
                try device.lockForConfiguration()
                let canLockFocus = device.isFocusModeSupported(.locked)
                let canLockExposure = device.isExposureModeSupported(.locked)
                if canLockFocus {
                    device.focusMode = .locked
                }
                if canLockExposure {
                    device.exposureMode = .locked
                }
                device.unlockForConfiguration()
                self.publish {
                    self.isFocusExposureLocked = canLockFocus || canLockExposure
                }
            } catch {
                self.showError("Couldn’t lock focus and exposure.")
            }
        }
        pendingFocusLockWorkItem = workItem
        sessionQueue.asyncAfter(deadline: .now() + 0.45, execute: workItem)
    }

    private func applyActiveModeFormat() {
        if captureMode == .photo {
            applyBestPhotoFormat()
        } else {
            applySelectedFormat()
        }
    }

    private func applyBestPhotoFormat() {
        guard let currentDevice = videoInput?.device else { return }
        let devices = capabilityDevices(for: currentDevice.position)
        let desiredType: AVCaptureDevice.DeviceType = requestedZoom < 1 ? .builtInUltraWideCamera : .builtInWideAngleCamera
        // Prefer a virtual multi-camera input so 0.5× <-> 1× stays inside one capture input.
        // Replacing AVCaptureDeviceInput is much slower and causes the visible one-second hitch.
        let desiredDevice = devices.first(where: { $0.isVirtualDevice })
            ?? devices.first(where: { $0.deviceType == desiredType })
            ?? devices.first(where: { !$0.isVirtualDevice })
            ?? devices.first

        guard let desiredDevice else {
            showError("Photo capture is unavailable on this camera.")
            return
        }

        let switchedPhysicalCamera = desiredDevice.uniqueID != currentDevice.uniqueID
        if switchedPhysicalCamera,
           replaceVideoInput(with: desiredDevice) == false {
            showError("Couldn’t switch cameras for Photo mode.")
            return
        }

        guard let device = videoInput?.device,
              let photoChoice = bestPhotoFormat(for: device) else {
            showError("Full-resolution photos aren’t available on this camera.")
            return
        }

        do {
            try device.lockForConfiguration()
            device.activeFormat = photoChoice.format
            if let range = photoChoice.format.videoSupportedFrameRateRanges.first(where: {
                $0.minFrameRate <= 30 && $0.maxFrameRate >= 30
            }) ?? photoChoice.format.videoSupportedFrameRateRanges.first {
                let actualRate = min(max(30.0, range.minFrameRate), range.maxFrameRate)
                let duration = CMTimeMakeWithSeconds(1.0 / actualRate, preferredTimescale: 60_000)
                device.activeVideoMinFrameDuration = duration
                device.activeVideoMaxFrameDuration = duration
            }
            let displayedZoom = snappedZoomFactor(requestedZoom, for: device)
            device.videoZoomFactor = deviceZoomFactor(for: displayedZoom, device: device)
            device.unlockForConfiguration()

            if photoOutput.maxPhotoDimensions.width != photoChoice.dimensions.width ||
                photoOutput.maxPhotoDimensions.height != photoChoice.dimensions.height {
                photoOutput.maxPhotoDimensions = photoChoice.dimensions
            }

            let minimum = devices.map { self.minimumSupportedZoom(for: $0) }.min() ?? 1
            let maximum = devices.map { self.maximumSupportedZoom(for: $0) }.max() ?? 1
            publish {
                self.minimumZoomFactor = minimum
                self.maximumZoomFactor = maximum
                self.zoomFactor = displayedZoom
                self.zoomLabel = self.formattedZoomLabel(for: displayedZoom)
                self.torchAvailable = device.hasTorch
                self.isTorchOn = device.torchMode == .on
            }
            if switchedPhysicalCamera {
                resetFocusAndExposureState()
            }
        } catch {
            showError("Couldn’t configure full-resolution Photo mode.")
        }
    }

    private func bestPhotoFormat(for device: AVCaptureDevice) -> (format: AVCaptureDevice.Format, dimensions: CMVideoDimensions)? {
        struct Candidate {
            let format: AVCaptureDevice.Format
            let photoDimensions: CMVideoDimensions
            let photoPixels: Int64
            let previewPixels: Int64
            let supports30FPS: Bool
        }

        var best: Candidate?
        for format in device.formats {
            guard let photoDimensions = format.supportedMaxPhotoDimensions.max(by: { lhs, rhs in
                Int64(lhs.width) * Int64(lhs.height) < Int64(rhs.width) * Int64(rhs.height)
            }) else { continue }

            let videoDimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let candidate = Candidate(
                format: format,
                photoDimensions: photoDimensions,
                photoPixels: Int64(photoDimensions.width) * Int64(photoDimensions.height),
                previewPixels: Int64(videoDimensions.width) * Int64(videoDimensions.height),
                supports30FPS: format.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= 30 && $0.maxFrameRate >= 30 }
            )

            guard let current = best else {
                best = candidate
                continue
            }

            // Max still-photo resolution always wins. For formats that produce the same
            // max-resolution photo, prefer 30 fps and then the sharpest live-preview format.
            if candidate.photoPixels > current.photoPixels ||
                (candidate.photoPixels == current.photoPixels && candidate.supports30FPS && !current.supports30FPS) ||
                (candidate.photoPixels == current.photoPixels && candidate.supports30FPS == current.supports30FPS && candidate.previewPixels > current.previewPixels) {
                best = candidate
            }
        }

        guard let best else { return nil }
        return (best.format, best.photoDimensions)
    }

    private func configurePhotoOutputForActiveFormat(_ device: AVCaptureDevice) {
        guard let largest = device.activeFormat.supportedMaxPhotoDimensions.max(by: { lhs, rhs in
            Int64(lhs.width) * Int64(lhs.height) < Int64(rhs.width) * Int64(rhs.height)
        }) else { return }

        if photoOutput.maxPhotoDimensions.width != largest.width ||
            photoOutput.maxPhotoDimensions.height != largest.height {
            photoOutput.maxPhotoDimensions = largest
        }
    }

    private func minimumSupportedZoom(for device: AVCaptureDevice) -> CGFloat {
        max(0.5, displayedZoomFactor(for: device.minAvailableVideoZoomFactor, device: device))
    }

    private func maximumSupportedZoom(for device: AVCaptureDevice) -> CGFloat {
        min(8, displayedZoomFactor(for: device.maxAvailableVideoZoomFactor, device: device))
    }

    private func snappedZoomFactor(_ requestedFactor: CGFloat, for device: AVCaptureDevice) -> CGFloat {
        let minimum = minimumSupportedZoom(for: device)
        let maximum = maximumSupportedZoom(for: device)
        let clamped = min(max(requestedFactor, minimum), maximum)

        if minimum <= 0.5, abs(clamped - 0.5) < 0.10 {
            return 0.5
        }
        if abs(clamped - 1) < 0.16 {
            return 1
        }
        return clamped
    }

    private func resetZoomToOne() {
        requestedZoom = 1
        applyActiveModeFormat()
        guard let device = videoInput?.device else { return }
        let oneX = min(max(1, minimumSupportedZoom(for: device)), maximumSupportedZoom(for: device))
        do {
            try device.lockForConfiguration()
            device.videoZoomFactor = deviceZoomFactor(for: oneX, device: device)
            device.unlockForConfiguration()
            publish {
                self.zoomFactor = oneX
                self.zoomLabel = self.formattedZoomLabel(for: oneX)
            }
        } catch {
            showError("Couldn’t reset the zoom.")
        }
    }

    private func wideAngleDeviceZoomFactor(for device: AVCaptureDevice) -> CGFloat {
        if device.deviceType == .builtInUltraWideCamera { return 2 }
        let hasUltraWide = device.constituentDevices.contains { $0.deviceType == .builtInUltraWideCamera }
        guard hasUltraWide, let switchFactor = device.virtualDeviceSwitchOverVideoZoomFactors.first else {
            return 1
        }
        return CGFloat(switchFactor.doubleValue)
    }

    private func displayedZoomFactor(for deviceZoomFactor: CGFloat, device: AVCaptureDevice) -> CGFloat {
        deviceZoomFactor / wideAngleDeviceZoomFactor(for: device)
    }

    private func deviceZoomFactor(for displayedZoomFactor: CGFloat, device: AVCaptureDevice) -> CGFloat {
        let requested = displayedZoomFactor * wideAngleDeviceZoomFactor(for: device)
        return min(max(requested, device.minAvailableVideoZoomFactor), device.maxAvailableVideoZoomFactor)
    }

    private func formattedZoomLabel(for zoomFactor: CGFloat) -> String {
        abs(zoomFactor.rounded() - zoomFactor) < 0.01
            ? "\(Int(zoomFactor.rounded()))×"
            : String(format: "%.1f×", zoomFactor)
    }

    private func availableResolutions(for devices: [AVCaptureDevice]) -> [VideoResolution] {
        VideoResolution.allCases.filter { resolution in
            devices.contains { device in
                device.formats.contains { self.format($0, supports: resolution) }
            }
        }
    }

    private func validSelection(for devices: [AVCaptureDevice], availableResolutions: [VideoResolution]) -> (resolution: VideoResolution, frameRate: VideoFrameRate, supportedFrameRates: [VideoFrameRate]) {
        let resolution = availableResolutions.contains(selectedResolution) ? selectedResolution : (availableResolutions.first ?? .p1080)
        let rates = frameRates(for: resolution, devices: devices)
        let frameRate = rates.contains(selectedFrameRate) ? selectedFrameRate : (rates.first ?? .fps30)
        return (resolution, frameRate, rates)
    }

    private func applySelectedFormat() {
        guard let currentDevice = videoInput?.device else { return }
        let devices = capabilityDevices(for: currentDevice.position)
        let selection = validSelection(for: devices, availableResolutions: availableResolutions(for: devices))
        let supportedDevices = devices.filter { device in
            device.formats.contains { self.format($0, supports: selection.resolution, at: selection.frameRate) }
        }
        let desiredType: AVCaptureDevice.DeviceType = requestedZoom < 1 ? .builtInUltraWideCamera : .builtInWideAngleCamera
        guard let desiredDevice = supportedDevices.first(where: { $0.isVirtualDevice })
            ?? supportedDevices.first(where: { $0.deviceType == desiredType })
            ?? supportedDevices.first else {
            showError("This video quality isn’t available on this camera.")
            return
        }

        let switchedPhysicalCamera = desiredDevice.uniqueID != currentDevice.uniqueID
        if switchedPhysicalCamera,
           replaceVideoInput(with: desiredDevice) == false {
            showError("Couldn’t switch cameras for this video quality.")
            return
        }

        guard let device = videoInput?.device else { return }
        publish {
            self.selectedResolution = selection.resolution
            self.selectedFrameRate = selection.frameRate
            self.supportedFrameRates = selection.supportedFrameRates
        }
        guard let format = device.formats.first(where: {
            self.format($0, supports: selection.resolution, at: selection.frameRate)
        }) else {
            showError("This video quality isn’t available on this camera.")
            return
        }
        do {
            try device.lockForConfiguration()
            device.activeFormat = format
            let requestedRate = Double(selection.frameRate.rawValue)
            let range = format.videoSupportedFrameRateRanges.first {
                $0.minFrameRate <= requestedRate + 0.5 && $0.maxFrameRate >= requestedRate - 0.5
            }
            let actualRate = min(max(requestedRate, range?.minFrameRate ?? requestedRate), range?.maxFrameRate ?? requestedRate)
            let duration = CMTimeMakeWithSeconds(1 / actualRate, preferredTimescale: 60_000)
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
            device.unlockForConfiguration()
            configurePhotoOutputForActiveFormat(device)
            let minimum = supportedDevices.map { self.minimumSupportedZoom(for: $0) }.min() ?? 1
            let maximum = supportedDevices.map { self.maximumSupportedZoom(for: $0) }.max() ?? 1
            publish {
                self.minimumZoomFactor = minimum
                self.maximumZoomFactor = maximum
                self.torchAvailable = device.hasTorch
                self.isTorchOn = device.torchMode == .on
            }
            if switchedPhysicalCamera {
                resetFocusAndExposureState()
            }
        } catch {
            showError("Couldn’t set the video quality.")
        }
    }

    private func format(_ format: AVCaptureDevice.Format, supports resolution: VideoResolution, at frameRate: VideoFrameRate? = nil) -> Bool {
        let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        guard dimensions.width == resolution.dimensions.width, dimensions.height == resolution.dimensions.height else { return false }
        guard let frameRate else { return true }
        return format.videoSupportedFrameRateRanges.contains {
            let requestedRate = Double(frameRate.rawValue)
            return $0.minFrameRate <= requestedRate + 0.5 && $0.maxFrameRate >= requestedRate - 0.5
        }
    }

    private func frameRates(for resolution: VideoResolution, devices: [AVCaptureDevice]) -> [VideoFrameRate] {
        VideoFrameRate.allCases.filter { rate in
            devices.contains { device in
                device.formats.contains { format($0, supports: resolution, at: rate) }
            }
        }
    }

    private func beginPhotoCapture() {
        guard session.isRunning else {
            publish { self.isCapturingPhoto = false }
            showError("Camera isn’t ready yet.")
            return
        }

        let settings = AVCapturePhotoSettings()
        settings.photoQualityPrioritization = .quality
        let dimensions = photoOutput.maxPhotoDimensions
        if dimensions.width > 0, dimensions.height > 0 {
            settings.maxPhotoDimensions = dimensions
        }
        photoOutput.capturePhoto(with: settings, delegate: self)
    }

    private func beginRecording() {
        guard session.isRunning, movieOutput.isRecording == false else { return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mov")
        movieOutput.startRecording(to: url, recordingDelegate: self)
    }

    private func synchronizeTorchState() {
        guard let device = videoInput?.device else {
            publish {
                self.torchAvailable = false
                self.isTorchOn = false
            }
            return
        }
        publish {
            self.torchAvailable = device.hasTorch
            self.isTorchOn = device.hasTorch && device.torchMode == .on
        }
    }

    private func publish(_ update: @escaping () -> Void) {
        DispatchQueue.main.async(execute: update)
    }

    private func showError(_ message: String) {
        publish { self.statusMessage = message }
    }
}

extension CameraManager: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        publish {
            self.isRecording = true
            self.recordingStartedAt = Date()
            self.durationTimer?.invalidate()
            self.durationTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                guard let startedAt = self?.recordingStartedAt else { return }
                self?.recordingDuration = Date().timeIntervalSince(startedAt)
            }
        }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        publish {
            self.isRecording = false
            self.recordingDuration = 0
            self.recordingStartedAt = nil
            self.durationTimer?.invalidate()
        }

        if let error {
            showError("Recording stopped: \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: outputFileURL)
            return
        }

        PHPhotoLibrary.shared().performChanges({
            PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL: outputFileURL)
        }) { [weak self] success, error in
            try? FileManager.default.removeItem(at: outputFileURL)
            if success {
                self?.publish { self?.statusMessage = "Saved to Photos" }
            } else {
                self?.showError(error?.localizedDescription ?? "Couldn’t save the video to Photos.")
            }
        }
    }
}


extension CameraManager: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error {
            showError("Photo failed: \(error.localizedDescription)")
            return
        }

        guard let data = photo.fileDataRepresentation() else {
            showError("Couldn’t create the photo file.")
            return
        }

        PHPhotoLibrary.shared().performChanges({
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, data: data, options: nil)
        }) { [weak self] success, error in
            if success {
                self?.publish { self?.statusMessage = "Photo saved to Photos" }
            } else {
                self?.showError(error?.localizedDescription ?? "Couldn’t save the photo to Photos.")
            }
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        publish {
            self.isCapturingPhoto = false
        }

        if let error {
            showError("Photo capture failed: \(error.localizedDescription)")
        }
    }
}
