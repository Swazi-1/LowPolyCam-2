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
    @Published private(set) var activeLensLabel = "1×"
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
                device.videoZoomFactor = factor
                device.unlockForConfiguration()
                let lensLabel = self.lensLabel(for: factor, minimumZoom: self.minimumSupportedZoom(for: device))
                self.publish {
                    self.zoomFactor = factor
                    self.activeLensLabel = lensLabel
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
        guard let device = preferredCamera(for: position) else {
            return false
        }
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else { return false }
            session.addInput(input)
            videoInput = input
            return true
        } catch {
            showError("Couldn’t access the camera.")
            return false
        }
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
        let supported = availableResolutions(for: device)
        let selection = validSelection(for: device, availableResolutions: supported)
        publish {
            self.supportedResolutions = supported
            self.torchAvailable = device.hasTorch
            self.isTorchOn = device.torchMode == .on
            self.minimumZoomFactor = self.minimumSupportedZoom(for: device)
            self.maximumZoomFactor = self.maximumSupportedZoom(for: device)
            self.zoomFactor = device.videoZoomFactor
            self.activeLensLabel = self.lensLabel(for: device.videoZoomFactor, minimumZoom: self.minimumSupportedZoom(for: device))
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

    private func minimumSupportedZoom(for device: AVCaptureDevice) -> CGFloat {
        max(0.5, device.minAvailableVideoZoomFactor)
    }

    private func maximumSupportedZoom(for device: AVCaptureDevice) -> CGFloat {
        min(8, device.maxAvailableVideoZoomFactor)
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

    private func lensLabel(for zoomFactor: CGFloat, minimumZoom: CGFloat) -> String {
        minimumZoom <= 0.5 && zoomFactor < 0.75 ? "0.5×" : "1×"
    }

    private func availableResolutions(for device: AVCaptureDevice) -> [VideoResolution] {
        VideoResolution.allCases.filter { resolution in
            device.formats.contains { self.format($0, supports: resolution) }
        }
    }

    private func validSelection(for device: AVCaptureDevice, availableResolutions: [VideoResolution]) -> (resolution: VideoResolution, frameRate: VideoFrameRate, supportedFrameRates: [VideoFrameRate]) {
        let resolution = availableResolutions.contains(selectedResolution) ? selectedResolution : (availableResolutions.first ?? .p1080)
        let rates = frameRates(for: resolution, device: device)
        let frameRate = rates.contains(selectedFrameRate) ? selectedFrameRate : (rates.first ?? .fps30)
        return (resolution, frameRate, rates)
    }

    private func applySelectedFormat() {
        guard let device = videoInput?.device else { return }
        let selection = validSelection(for: device, availableResolutions: availableResolutions(for: device))
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
            let duration = CMTime(value: 1, timescale: CMTimeScale(selectedFrameRate.rawValue))
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
            $0.minFrameRate <= Double(frameRate.rawValue) && $0.maxFrameRate >= Double(frameRate.rawValue)
        }
    }

    private func frameRates(for resolution: VideoResolution, device: AVCaptureDevice) -> [VideoFrameRate] {
        VideoFrameRate.allCases.filter { rate in
            device.formats.contains { format($0, supports: resolution, at: rate) }
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
