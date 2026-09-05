import AVFoundation
import Photos

final class CameraManager: NSObject, ObservableObject {
    enum CameraPosition {
        case back
        case front

        var avPosition: AVCaptureDevice.Position {
            self == .back ? .back : .front
        }
    }

    @Published private(set) var isSessionRunning = false
    @Published private(set) var isRecording = false
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
    private var videoInput: AVCaptureDeviceInput?
    private var durationTimer: Timer?
    private var recordingStartedAt: Date?

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
        sessionQueue.async { [weak self] in
            guard let self, let device = self.videoInput?.device else { return }
            let factor = self.snappedZoomFactor(requestedFactor, for: device)
            do {
                try device.lockForConfiguration()
                device.ramp(toVideoZoomFactor: self.deviceZoomFactor(for: factor, device: device), withRate: 14)
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

    func switchCamera() {
        guard !isRecording else { return }
        cameraPosition = cameraPosition == .back ? .front : .back
        sessionQueue.async { [weak self] in self?.reconfigureCamera() }
    }

    func selectResolution(_ resolution: VideoResolution) {
        selectedResolution = resolution
        sessionQueue.async { [weak self] in self?.applySelectedFormat() }
    }

    func selectFrameRate(_ frameRate: VideoFrameRate) {
        selectedFrameRate = frameRate
        sessionQueue.async { [weak self] in self?.applySelectedFormat() }
    }

    func startOrStopRecording() {
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
        updateCapabilities()
        applySelectedFormat()
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
        applySelectedFormat()
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
        return devices
    }

    private func cameraSupportingCurrentQuality(for position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        capabilityDevices(for: position).first { device in
            device.formats.contains { format($0, supports: selectedResolution, at: selectedFrameRate) }
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
        guard let desiredDevice = devices.first(where: { device in
            device.formats.contains { self.format($0, supports: selection.resolution, at: selection.frameRate) }
        }) else {
            showError("This video quality isn’t available on this camera.")
            return
        }

        if desiredDevice.uniqueID != currentDevice.uniqueID,
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

    private func beginRecording() {
        guard session.isRunning, movieOutput.isRecording == false else { return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mov")
        movieOutput.startRecording(to: url, recordingDelegate: self)
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
