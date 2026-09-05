import SwiftUI
import Foundation
import CoreMotion
import UIKit

struct CameraIconButton: View {
    let symbol: String
    let isEnabled: Bool
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
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
    let isRecording: Bool
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
        .accessibilityLabel(isRecording ? "Stop recording" : "Start recording")
    }
}

struct PhotoButton: View {
    let isCapturing: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .stroke(.white, lineWidth: 4)
                    .frame(width: 76, height: 76)
                Circle()
                    .fill(.white)
                    .frame(width: 62, height: 62)
                    .scaleEffect(isCapturing ? 0.86 : 1)
            }
            .animation(.easeOut(duration: 0.12), value: isCapturing)
        }
        .disabled(isCapturing)
        .accessibilityLabel("Take photo")
    }
}

struct CaptureModeSelector: View {
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
                        .foregroundStyle(selectedMode == mode ? .yellow : .white.opacity(0.65))
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
    @ObservedObject var camera: CameraManager
    let showResolution: Bool
    let showFPS: Bool
    let showRemaining: Bool
    let showZoom: Bool
    let showWhiteBalance: Bool
    let maxWidth: CGFloat

    var body: some View {
        Text(displayText)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.62)
            .allowsTightening(true)
            .foregroundStyle(.white)
            .padding(.horizontal, 13)
            .frame(height: 34)
            .frame(maxWidth: maxWidth)
            .background(.black.opacity(0.86), in: Capsule())
            .overlay {
                Capsule().stroke(.white.opacity(0.08), lineWidth: 1)
            }
            .accessibilityLabel(items.joined(separator: ", "))
    }

    private var displayText: String {
        items.joined(separator: "  ·  ")
    }

    private var items: [String] {
        var result: [String] = []
        if showResolution { result.append(camera.hudResolutionLabel) }
        if showFPS, let fps = camera.hudFrameRateLabel { result.append("\(fps)fps") }
        if showRemaining { result.append(camera.hudRemainingLabel) }
        if showZoom { result.append(camera.zoomLabel) }
        if showWhiteBalance { result.append(whiteBalanceShortLabel) }
        if result.isEmpty { result.append(camera.captureMode.rawValue) }
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
}

struct ProToolsPopup: View {
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
                        .foregroundStyle(.yellow)
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
                .tint(.yellow)
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
                    .foregroundStyle(.yellow)
                }
            }

            Divider()
                .overlay(.white.opacity(0.15))

            Toggle("Level Meter", isOn: $isLevelMeterEnabled)
                .font(.subheadline.weight(.semibold))
                .tint(.yellow)
        }
        .foregroundStyle(.white)
        .padding(16)
        .frame(width: 310)
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
                .fill(isLevel ? .yellow : .white)
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
            let nearestLevel = (self.unwrappedRoll / quarterTurn).rounded() * quarterTurn
            self.levelDeviation = abs(self.unwrappedRoll - nearestLevel)
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
        levelDeviation = .infinity
        isAvailable = false
    }
}
