import AVFoundation
import Foundation

/// Session-queue-owned cache for stable camera topology and format-selection results.
/// Dynamic hardware state (active zoom/WB/readiness/connections) is intentionally not cached.
final class CameraCapabilityCache {
    private var deviceInventory: [Int: [AVCaptureDevice]] = [:]
    private var availableVideoResolutions: [String: [VideoResolution]] = [:]
    private var videoFrameRates: [String: [VideoFrameRate]] = [:]
    private var videoDevices: [String: [AVCaptureDevice]] = [:]
    private var recordingFormats: [String: AVCaptureDevice.Format] = [:]
    private var slowMotionResolutions: [String: [VideoResolution]] = [:]
    private var slowMotionFrameRates: [String: [CameraManager.SlowMotionFrameRate]] = [:]
    private var slowMotionDevices: [String: [AVCaptureDevice]] = [:]
    private var slowMotionFormats: [String: AVCaptureDevice.Format] = [:]

    func invalidateAll() {
        deviceInventory.removeAll(keepingCapacity: true)
        availableVideoResolutions.removeAll(keepingCapacity: true)
        videoFrameRates.removeAll(keepingCapacity: true)
        videoDevices.removeAll(keepingCapacity: true)
        recordingFormats.removeAll(keepingCapacity: true)
        slowMotionResolutions.removeAll(keepingCapacity: true)
        slowMotionFrameRates.removeAll(keepingCapacity: true)
        slowMotionDevices.removeAll(keepingCapacity: true)
        slowMotionFormats.removeAll(keepingCapacity: true)
    }

    func devices(for position: AVCaptureDevice.Position, discover: () -> [AVCaptureDevice]) -> [AVCaptureDevice] {
        let key = position.rawValue
        if let cached = deviceInventory[key] { return cached }
        let value = discover()
        deviceInventory[key] = value
        return value
    }

    func videoResolutions(devices: [AVCaptureDevice], codec: String, compute: () -> [VideoResolution]) -> [VideoResolution] {
        let key = "v-res|\(deviceSignature(devices))|\(codec)"
        if let cached = availableVideoResolutions[key] { return cached }
        let value = compute()
        availableVideoResolutions[key] = value
        return value
    }

    func frameRates(devices: [AVCaptureDevice], resolution: VideoResolution, codec: String, compute: () -> [VideoFrameRate]) -> [VideoFrameRate] {
        let key = "v-fps|\(deviceSignature(devices))|\(resolution.rawValue)|\(codec)"
        if let cached = videoFrameRates[key] { return cached }
        let value = compute()
        videoFrameRates[key] = value
        return value
    }

    func compatibleVideoDevices(devices: [AVCaptureDevice], resolution: VideoResolution, frameRate: VideoFrameRate, codec: String, compute: () -> [AVCaptureDevice]) -> [AVCaptureDevice] {
        let key = "v-dev|\(deviceSignature(devices))|\(resolution.rawValue)|\(frameRate.rawValue)|\(codec)"
        if let cached = videoDevices[key] { return cached }
        let value = compute()
        videoDevices[key] = value
        return value
    }

    func recordingFormat(device: AVCaptureDevice, resolution: VideoResolution, frameRate: VideoFrameRate, codec: String, compute: () -> AVCaptureDevice.Format?) -> AVCaptureDevice.Format? {
        let key = "v-format|\(device.uniqueID)|\(resolution.rawValue)|\(frameRate.rawValue)|\(codec)"
        if let cached = recordingFormats[key] { return cached }
        guard let value = compute() else { return nil }
        recordingFormats[key] = value
        return value
    }

    func hfrResolutions(devices: [AVCaptureDevice], codec: String, compute: () -> [VideoResolution]) -> [VideoResolution] {
        let key = "h-res|\(deviceSignature(devices))|\(codec)"
        if let cached = slowMotionResolutions[key] { return cached }
        let value = compute()
        slowMotionResolutions[key] = value
        return value
    }

    func hfrFrameRates(devices: [AVCaptureDevice], resolution: VideoResolution, codec: String, compute: () -> [CameraManager.SlowMotionFrameRate]) -> [CameraManager.SlowMotionFrameRate] {
        let key = "h-fps|\(deviceSignature(devices))|\(resolution.rawValue)|\(codec)"
        if let cached = slowMotionFrameRates[key] { return cached }
        let value = compute()
        slowMotionFrameRates[key] = value
        return value
    }

    func compatibleHFRDevices(devices: [AVCaptureDevice], resolution: VideoResolution, frameRate: CameraManager.SlowMotionFrameRate, codec: String, compute: () -> [AVCaptureDevice]) -> [AVCaptureDevice] {
        let key = "h-dev|\(deviceSignature(devices))|\(resolution.rawValue)|\(frameRate.rawValue)|\(codec)"
        if let cached = slowMotionDevices[key] { return cached }
        let value = compute()
        slowMotionDevices[key] = value
        return value
    }

    func hfrFormat(device: AVCaptureDevice, resolution: VideoResolution, frameRate: CameraManager.SlowMotionFrameRate, codec: String, compute: () -> AVCaptureDevice.Format?) -> AVCaptureDevice.Format? {
        let key = "h-format|\(device.uniqueID)|\(resolution.rawValue)|\(frameRate.rawValue)|\(codec)"
        if let cached = slowMotionFormats[key] { return cached }
        guard let value = compute() else { return nil }
        slowMotionFormats[key] = value
        return value
    }

    private func deviceSignature(_ devices: [AVCaptureDevice]) -> String {
        devices.map(\.uniqueID).sorted().joined(separator: ",")
    }
}
