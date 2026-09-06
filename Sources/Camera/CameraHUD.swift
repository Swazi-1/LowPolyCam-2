import SwiftUI
import UIKit

/// The compact camera status pill. HUD presentation lives here so CameraManager only exposes
/// capture state; it does not need to know how that state is arranged or which SF Symbol is used.
struct CameraHUD: View {
    @Environment(\.cameraTint) private var theme
    @ObservedObject var camera: CameraManager
    @AppStorage("cameraHUDBattery") private var showBattery = false
    @AppStorage("cameraHUDStorage") private var showStorage = false
    @AppStorage("cameraHUDDroppedFrames") private var showDroppedFrames = false
    @AppStorage("cameraHUDAudioMeter") private var showAudioMeter = false
    @AppStorage("thermalHUD") private var showThermal = false
    @AppStorage("hudTextSize") private var hudTextSize = 10.0
    @State private var batteryLevel: Float = -1
    @State private var thermalState = ProcessInfo.processInfo.thermalState

    let showResolution: Bool
    let showFPS: Bool
    let showRemaining: Bool
    let showWhiteBalance: Bool
    let maxWidth: CGFloat

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 5) {
                Circle()
                    .fill(camera.isRecording ? Color.red : theme)
                    .frame(width: 5, height: 5)

                Text(camera.isRecording ? "REC" : camera.captureMode.rawValue)
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(theme)

                if camera.isRecording {
                    Text(recordingTime)
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                }

                if showAudioMeter, camera.captureMode != .photo, camera.isRecording {
                    AudioLevelBars(level: camera.audioLevel)
                }
            }

            if !items.isEmpty {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        ForEach(items) { item in
                            Label(item.text, systemImage: item.symbol)
                        }
                    }
                    .fixedSize(horizontal: true, vertical: false)

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 4) {
                        ForEach(items) { item in
                            Label(item.text, systemImage: item.symbol)
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                        }
                    }
                    .frame(maxWidth: maxWidth - 20)
                }
            }
        }
        .font(.system(size: hudTextSize, weight: .semibold, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(theme)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 20))
        .background(theme.opacity(0.22), in: RoundedRectangle(cornerRadius: 20))
        .overlay {
            RoundedRectangle(cornerRadius: 20)
                .stroke(theme.opacity(0.35), lineWidth: 1)
        }
        .frame(maxWidth: maxWidth)
        .accessibilityLabel(([camera.captureMode.rawValue] + items.map(\.text)).joined(separator: ", "))
        .task(id: showBattery) {
            UIDevice.current.isBatteryMonitoringEnabled = showBattery
            batteryLevel = showBattery ? UIDevice.current.batteryLevel : -1
        }
        .onDisappear {
            if showBattery { UIDevice.current.isBatteryMonitoringEnabled = false }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryLevelDidChangeNotification)) { _ in
            batteryLevel = UIDevice.current.batteryLevel
        }
        .onReceive(NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)) { _ in
            thermalState = ProcessInfo.processInfo.thermalState
        }
    }

    private var recordingTime: String {
        let seconds = Int(camera.recordingDuration)
        return String(format: "%02d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
    }

    private var items: [CameraHUDItem] {
        var result: [CameraHUDItem] = []

        if showResolution {
            result.append(.init(id: .resolution, text: camera.hudResolutionLabel, symbol: "viewfinder"))
        }
        if showFPS, let fps = camera.hudFrameRateLabel {
            result.append(.init(id: .fps, text: "\(fps)fps", symbol: "speedometer"))
        }
        if showRemaining {
            let symbol = camera.captureMode == .photo ? "photo.on.rectangle" : "clock"
            result.append(.init(id: .remaining, text: camera.hudRemainingLabel, symbol: symbol))
        }
        if showWhiteBalance {
            result.append(.init(id: .whiteBalance, text: whiteBalanceShortLabel, symbol: "sun.max"))
        }
        if showBattery {
            let text = batteryLevel < 0 ? "BAT —" : "BAT \(Int(batteryLevel * 100))%"
            result.append(.init(id: .battery, text: text, symbol: "battery.100percent"))
        }
        if showStorage {
            let text = String(format: "%.1f GB", Double(camera.availableStorageBytes) / 1_000_000_000)
            result.append(.init(id: .storage, text: text, symbol: "internaldrive"))
        }
        if showThermal {
            result.append(.init(id: .thermal, text: thermalLabel, symbol: "thermometer.medium"))
        }
        if showDroppedFrames, camera.captureMode != .photo {
            let text = camera.lastFrameGaps.map { "Gaps \($0)*" } ?? "Gaps —*"
            result.append(.init(id: .frameGaps, text: text, symbol: "waveform.path"))
        }

        return result
    }

    private var whiteBalanceShortLabel: String {
        switch camera.whiteBalancePreset {
        case .auto: return "AWB"
        case .daylight: return "Day"
        case .cloudy: return "Cloud"
        case .tungsten: return "Tung"
        case .fluorescent: return "Fluor"
        }
    }

    private var thermalLabel: String {
        switch thermalState {
        case .nominal: return "Cool"
        case .fair: return "Warm"
        case .serious: return "Hot"
        case .critical: return "Critical"
        @unknown default: return "Temp —"
        }
    }
}

private struct CameraHUDItem: Identifiable {
    enum ID: Hashable {
        case resolution, fps, remaining, whiteBalance, battery, storage, thermal, frameGaps
    }

    let id: ID
    let text: String
    let symbol: String
}

private struct AudioLevelBars: View {
    @Environment(\.cameraTint) private var theme
    let level: CGFloat

    private let heights: [CGFloat] = [4, 7, 10, 13]
    private let thresholds: [CGFloat] = [0.10, 0.28, 0.50, 0.74]

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(Array(heights.enumerated()), id: \.offset) { index, height in
                Capsule()
                    .fill(level >= thresholds[index] ? theme : .white.opacity(0.26))
                    .frame(width: 2.5, height: height)
            }
        }
        .frame(width: 18, height: 14, alignment: .bottom)
        .accessibilityLabel("Microphone level")
    }
}


extension CameraManager {
    var hudResolutionLabel: String {
        switch captureMode {
        case .video: return selectedResolution.rawValue
        case .sloMo: return selectedSlowMotionResolution.rawValue
        case .photo: return currentPhotoResolutionLabel
        }
    }

    var hudFrameRateLabel: String? {
        switch captureMode {
        case .video: return "\(selectedFrameRate.rawValue)"
        case .sloMo: return "\(selectedSlowMotionFrameRate.rawValue)"
        case .photo: return nil
        }
    }

    var hudRemainingLabel: String {
        switch captureMode {
        case .photo:
            return CaptureStorageEstimator.photoRemainingLabel(
                availableBytes: availableStorageBytes,
                pixelCount: currentPhotoPixelCount,
                fileFormat: photoFileFormat
            )
        case .video:
            return CaptureStorageEstimator.videoRemainingLabel(
                availableBytes: availableStorageBytes,
                resolution: selectedResolution,
                frameRate: Double(selectedFrameRate.rawValue),
                compression: videoCompression,
                codec: selectedVideoCodec
            )
        case .sloMo:
            return CaptureStorageEstimator.videoRemainingLabel(
                availableBytes: availableStorageBytes,
                resolution: selectedSlowMotionResolution,
                frameRate: Double(selectedSlowMotionFrameRate.rawValue),
                compression: videoCompression,
                codec: selectedVideoCodec
            )
        }
    }
}
