import SwiftUI
import Foundation
import CoreMotion
import UIKit

struct CameraIconButton: View {
    @Environment(\.cameraTint) private var theme
    let symbol: String
    let isEnabled: Bool
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: { CameraHaptics.fire(); action() }) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 48, height: 48)
                .background(.black.opacity(0.28), in: Circle())
        }
        .foregroundStyle(isEnabled ? color : .white.opacity(0.35))
        .disabled(!isEnabled)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        switch symbol {
        case "bolt.fill": return "Torch"
        case "gearshape.fill": return "Settings"
        case "ellipsis": return "Pro Tools"
        default: return "Switch camera"
        }
    }
}

struct RecordButton: View {
    @Environment(\.cameraTint) private var theme
    let isRecording: Bool
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(.white)
                    .frame(width: 76, height: 76)
                RoundedRectangle(cornerRadius: isRecording ? 7 : 34)
                    .fill(.red)
                    .frame(width: isRecording ? 30 : 62, height: isRecording ? 30 : 62)
            }
        }
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.55)
        .accessibilityLabel(isRecording ? "Stop recording" : "Start recording")
    }
}

struct PhotoButton: View {
    @Environment(\.cameraTint) private var theme
    let isCapturing: Bool
    let countdown: Int
    let countdownTotal: Int
    let previewImage: UIImage?
    var isEnabled = true
    let action: () -> Void
    let onBurstStart: () -> Void
    let onBurstEnd: () -> Void
    @State private var pressTask: Task<Void, Never>?
    @State private var isBurstActive = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(.white, lineWidth: 4)
                .frame(width: 76, height: 76)
            Circle()
                .fill(.white)
                .frame(width: 62, height: 62)
                .scaleEffect(isCapturing ? 0.86 : 1)

            if let previewImage, !isCapturing, countdown == 0 {
                Image(uiImage: previewImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 58, height: 58)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(.white.opacity(0.65), lineWidth: 1))
                    .transition(.scale(scale: 0.72).combined(with: .opacity))
            }

            if countdown > 0 {
                Circle()
                    .trim(from: 0, to: countdownProgress)
                    .stroke(theme, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 86, height: 86)
                    .animation(.linear(duration: 0.9), value: countdown)
                Text("\(countdown)")
                    .font(.system(.title3, design: .rounded).weight(.bold))
                    .foregroundStyle(.black)
            }
        }
        .animation(.easeOut(duration: 0.12), value: isCapturing)
        .animation(.spring(response: 0.24, dampingFraction: 0.78), value: previewImage != nil)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in beginPress() }
                .onEnded { _ in endPress() }
        )
        .opacity(isEnabled ? 1 : 0.55)
        .accessibilityLabel("Take photo")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { action() }
        .onDisappear { cancelPress() }
    }

    private var countdownProgress: CGFloat {
        guard countdownTotal > 0 else { return 0 }
        return max(0.04, min(CGFloat(countdown) / CGFloat(countdownTotal), 1))
    }

    private func beginPress() {
        guard isEnabled, !isCapturing, pressTask == nil else { return }
        pressTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 450_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled, !isCapturing else { return }
            isBurstActive = true
            pressTask = nil
            onBurstStart()
        }
    }

    private func endPress() {
        let didStartBurst = isBurstActive
        pressTask?.cancel()
        pressTask = nil
        isBurstActive = false

        if didStartBurst {
            onBurstEnd()
        } else if isEnabled, !isCapturing {
            action()
        }
    }

    private func cancelPress() {
        pressTask?.cancel()
        pressTask = nil
        guard isBurstActive else { return }
        isBurstActive = false
        onBurstEnd()
    }
}

struct CaptureModeSelector: View {
    @Environment(\.cameraTint) private var theme
    let selectedMode: CameraManager.CaptureMode
    let isEnabled: Bool
    let onSelect: (CameraManager.CaptureMode) -> Void

    var body: some View {
        HStack(spacing: 22) {
            ForEach(CameraManager.CaptureMode.allCases) { mode in
                Button {
                    onSelect(mode)
                } label: {
                    Text(mode.rawValue)
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(selectedMode == mode ? theme : .white.opacity(0.65))
                }
                .disabled(!isEnabled)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
        .background(.black.opacity(0.34), in: Capsule())
        .opacity(isEnabled ? 1 : 0.7)
    }
}

struct ZoomIndicator: View {
    @Environment(\.cameraTint) private var theme
    let label: String

    var body: some View {
        Text(label)
            .font(.system(.subheadline, design: .rounded).weight(.bold))
            .monospacedDigit()
            .padding(.horizontal, 13)
            .padding(.vertical, 7)
            .background(.black.opacity(0.42), in: Capsule())
            .foregroundStyle(.white)
            .accessibilityLabel("Active camera lens \(label)")
    }
}

struct RecordingTimer: View {
    @Environment(\.cameraTint) private var theme
    let duration: TimeInterval

    var body: some View {
        Text(timerText)
            .font(.system(.body, design: .monospaced).weight(.bold))
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(.red.opacity(0.92), in: Capsule())
            .foregroundStyle(.white)
    }

    private var timerText: String {
        let totalSeconds = Int(duration)
        return String(format: "%02d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}

struct CameraHUD: View {
    @Environment(\.cameraTint) private var theme
    @ObservedObject var camera: CameraManager
    @AppStorage("cameraHUDBattery") private var showBattery = false
    @AppStorage("cameraHUDStorage") private var showStorage = false
    @AppStorage("cameraHUDDroppedFrames") private var showDroppedFrames = false
    @AppStorage("cameraHUDAudioMeter") private var showAudioMeter = false
    @State private var batteryLevel: Float = -1
    @AppStorage("thermalHUD") private var showThermal = false
    @AppStorage("hudTextSize") private var hudTextSize = 10.0
    @State private var thermalState = ProcessInfo.processInfo.thermalState
    let showResolution: Bool
    let showFPS: Bool
    let showRemaining: Bool
    let showWhiteBalance: Bool
    let maxWidth: CGFloat

    // Keep showZoom as an ignored, defaulted compatibility argument so an older
    // CameraView/CameraControls pair cannot fail to compile during incremental updates.
    init(
        camera: CameraManager,
        showResolution: Bool,
        showFPS: Bool,
        showRemaining: Bool,
        showZoom: Bool = false,
        showWhiteBalance: Bool,
        maxWidth: CGFloat
    ) {
        _camera = ObservedObject(wrappedValue: camera)
        self.showResolution = showResolution
        self.showFPS = showFPS
        self.showRemaining = showRemaining
        self.showWhiteBalance = showWhiteBalance
        self.maxWidth = maxWidth
        _ = showZoom
    }

    var body: some View {
      VStack(spacing: 6) {
        HStack(spacing: 5) {
            Circle().fill(camera.isRecording ? Color.red : theme).frame(width: 5, height: 5)
            Text(camera.isRecording ? "REC" : camera.captureMode.rawValue)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(theme)
            if camera.isRecording {
                Text(String(format: "%02d:%02d:%02d", Int(camera.recordingDuration) / 3600, (Int(camera.recordingDuration) / 60) % 60, Int(camera.recordingDuration) % 60))
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
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        Label(item, systemImage: symbol(for: item))
                    }
                }
                .fixedSize(horizontal: true, vertical: false)

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 4) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        Label(item, systemImage: symbol(for: item))
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
                RoundedRectangle(cornerRadius: 20).stroke(theme.opacity(0.35), lineWidth: 1)
            }
            // Keep the black pill only as wide as its content. The outer frame centers it in the
            // safe gap between Flash and Settings without creating empty "Dynamic Island" space.
            .frame(maxWidth: maxWidth)
            .accessibilityLabel(([camera.captureMode.rawValue] + items).joined(separator: ", "))
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

    private var displayText: String {
        items.joined(separator: "  ·  ")
    }

    private var items: [String] {
        var result: [String] = []
        if showResolution { result.append(camera.hudResolutionLabel) }
        if showFPS, let fps = camera.hudFrameRateLabel { result.append("\(fps)fps") }
        if showRemaining { result.append(camera.hudRemainingLabel) }
        if showWhiteBalance { result.append(whiteBalanceShortLabel) }
        if showBattery { result.append(batteryLevel < 0 ? "BAT —" : "BAT \(Int(batteryLevel * 100))%") }
        if showStorage { result.append(String(format: "%.1f GB", Double(camera.availableStorageBytes) / 1_000_000_000)) }
        if showThermal {
            switch thermalState {
            case .nominal: result.append("Cool")
            case .fair: result.append("Warm")
            case .serious: result.append("Hot")
            case .critical: result.append("Critical")
            @unknown default: result.append("Temp —")
            }
        }
        if showDroppedFrames, camera.captureMode != .photo {
            result.append(camera.lastFrameGaps.map { "Gaps \($0)*" } ?? "Gaps —*")
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

    private func symbol(for item: String) -> String {
        if item.contains("fps") { return "speedometer" }
        if item.hasPrefix("BAT") { return "battery.100percent" }
        if item.contains("GB") { return "internaldrive" }
        if item.hasPrefix("Gaps") { return "waveform.path" }
        if ["Cool", "Warm", "Hot", "Critical", "Temp —"].contains(item) { return "thermometer.medium" }
        if item.hasPrefix("~") { return camera.captureMode == .photo ? "photo.on.rectangle" : "clock" }
        if item == whiteBalanceShortLabel { return "sun.max" }
        return "viewfinder"
    }
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

struct ProToolsPopup: View {
    @Environment(\.cameraTint) private var theme
    @ObservedObject var camera: CameraManager
    @Binding var isLevelMeterEnabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("PRO TOOLS")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.75))

            VStack(spacing: 8) {
                HStack {
                    Text("EV")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Button("Reset") {
                        camera.setExposureBias(0)
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.75))
                    .buttonStyle(.plain)
                    Text(evLabel)
                        .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                        .foregroundStyle(theme)
                        .frame(width: 42, alignment: .trailing)
                }

                Slider(
                    value: Binding(
                        get: { Double(camera.exposureBias) },
                        set: { camera.setExposureBias(Float($0)) }
                    ),
                    in: -2...2,
                    step: 0.1
                )
                .tint(theme)
            }

            Divider()
                .overlay(.white.opacity(0.15))

            HStack(spacing: 12) {
                Text("White Balance")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                Spacer(minLength: 8)

                Menu {
                    ForEach(CameraManager.WhiteBalancePreset.allCases) { preset in
                        Button {
                            camera.selectWhiteBalancePreset(preset)
                        } label: {
                            if camera.whiteBalancePreset == preset {
                                Label(preset.rawValue, systemImage: "checkmark")
                            } else {
                                Text(preset.rawValue)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(camera.whiteBalancePreset.rawValue)
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .frame(minWidth: 112, alignment: .trailing)
                    .foregroundStyle(theme)
                }
            }

            Divider()
                .overlay(.white.opacity(0.15))

            Toggle("Level Meter", isOn: $isLevelMeterEnabled)
                .font(.subheadline.weight(.semibold))
                .tint(theme)
        }
        .foregroundStyle(.white)
        .padding(16)
        .frame(maxWidth: 310)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.white.opacity(0.12), lineWidth: 1)
        }
    }

    private var evLabel: String {
        abs(camera.exposureBias) < 0.05 ? "0.0" : String(format: "%+.1f", camera.exposureBias)
    }
}

struct CameraLevelOverlay: View {
    @Environment(\.cameraTint) private var theme
    let angle: Double
    let isAvailable: Bool
    let isLevel: Bool

    var body: some View {
        ZStack {
            HStack(spacing: 132) {
                Capsule()
                    .fill(.white.opacity(0.72))
                    .frame(width: 52, height: 3)
                Capsule()
                    .fill(.white.opacity(0.72))
                    .frame(width: 52, height: 3)
            }

            Capsule()
                .fill(isLevel ? theme : .white)
                .frame(width: 104, height: isLevel ? 5 : 4)
                .rotationEffect(.radians(-angle))
        }
        .frame(width: 260, height: 72)
        .opacity(isAvailable ? 1 : 0.30)
        .animation(.easeOut(duration: 0.10), value: isLevel)
        .accessibilityLabel(isLevel ? "Camera level" : "Camera not level")
    }
}

struct CameraGridOverlay: View {
    @Environment(\.cameraTint) private var theme
    var body: some View {
        GeometryReader { geometry in
            Path { path in
                let width = geometry.size.width
                let height = geometry.size.height
                for fraction in [1.0 / 3.0, 2.0 / 3.0] {
                    path.move(to: CGPoint(x: width * fraction, y: 0))
                    path.addLine(to: CGPoint(x: width * fraction, y: height))
                    path.move(to: CGPoint(x: 0, y: height * fraction))
                    path.addLine(to: CGPoint(x: width, y: height * fraction))
                }
            }
            .stroke(.white.opacity(0.28), lineWidth: 0.8)
        }
    }
}

final class CameraLevelMonitor: ObservableObject {
    @Published private(set) var angle: Double = 0
    @Published private(set) var isAvailable = false
    @Published private(set) var levelDeviation: Double = .infinity

    private let motionManager = CMMotionManager()
    private var lastRawRoll: Double?
    private var unwrappedRoll: Double = 0

    var isLevel: Bool {
        let tolerance = 1.5 * Double.pi / 180
        return isAvailable && levelDeviation <= tolerance
    }

    func start() {
        guard motionManager.isDeviceMotionAvailable else {
            isAvailable = false
            return
        }
        guard !motionManager.isDeviceMotionActive else { return }

        motionManager.deviceMotionUpdateInterval = 1.0 / 30.0
        motionManager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: .main) { [weak self] motion, error in
            guard let self else { return }
            guard error == nil, let gravity = motion?.gravity else {
                self.resetMeasurement()
                return
            }

            let horizonStrength = hypot(gravity.x, gravity.y)
            guard horizonStrength > 0.06 else {
                self.resetMeasurement()
                return
            }

            let rawRoll = atan2(gravity.x, -gravity.y)
            if let lastRawRoll = self.lastRawRoll {
                // Unwrap the -π/+π boundary so the indicator keeps rotating continuously.
                let delta = atan2(sin(rawRoll - lastRawRoll), cos(rawRoll - lastRawRoll))
                self.unwrappedRoll += delta
                self.angle += (self.unwrappedRoll - self.angle) * 0.50
            } else {
                self.unwrappedRoll = rawRoll
                self.angle = rawRoll
            }
            self.lastRawRoll = rawRoll
            let quarterTurn = Double.pi / 2
            let nearestLevel = (self.angle / quarterTurn).rounded() * quarterTurn
            self.levelDeviation = abs(self.angle - nearestLevel)
            self.isAvailable = true
        }
    }

    func stop() {
        motionManager.stopDeviceMotionUpdates()
        resetMeasurement()
    }

    private func resetMeasurement() {
        lastRawRoll = nil
        unwrappedRoll = 0
        angle = 0
        levelDeviation = .infinity
        isAvailable = false
    }
}
