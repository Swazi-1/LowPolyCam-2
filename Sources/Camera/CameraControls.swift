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
                    Text(evLabel)
                        .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                        .foregroundStyle(.yellow)
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
                            .minimumScaleFactor(0.85)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .frame(minWidth: 105, alignment: .trailing)
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
        .frame(width: 300)
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
            HStack(spacing: 76) {
                Capsule()
                    .fill(.white.opacity(0.65))
                    .frame(width: 34, height: 2)
                Capsule()
                    .fill(.white.opacity(0.65))
                    .frame(width: 34, height: 2)
            }

            Capsule()
                .fill(isLevel ? .yellow : .white)
                .frame(width: 64, height: isLevel ? 3 : 2)
                .rotationEffect(.radians(angle))

            Circle()
                .fill(isLevel ? .yellow : .white.opacity(0.85))
                .frame(width: 4, height: 4)
        }
        .frame(width: 150, height: 44)
        .padding(.horizontal, 8)
        .background(.black.opacity(0.16), in: Capsule())
        .opacity(isAvailable ? 1 : 0.35)
        .animation(.easeOut(duration: 0.12), value: isLevel)
        .accessibilityLabel(isLevel ? "Camera level" : "Camera not level")
    }
}

final class CameraLevelMonitor: ObservableObject {
    @Published private(set) var angle: Double = 0
    @Published private(set) var isAvailable = false

    private let motionManager = CMMotionManager()
    private var hasInitialAngle = false
    private var lastOrientation: UIInterfaceOrientation?

    var degrees: Double { angle * 180 / .pi }
    var isLevel: Bool { isAvailable && abs(degrees) <= 1.25 }

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
                self.isAvailable = false
                self.hasInitialAngle = false
                return
            }

            // When the phone points almost perfectly straight up/down, a horizon roll angle
            // is physically ambiguous. Hide the live result instead of showing a jittery value.
            let horizonStrength = hypot(gravity.x, gravity.y)
            guard horizonStrength > 0.06 else {
                self.isAvailable = false
                self.hasInitialAngle = false
                return
            }

            let orientation = self.currentInterfaceOrientation()
            if orientation != self.lastOrientation {
                self.lastOrientation = orientation
                self.hasInitialAngle = false
            }

            let measured = self.normalizedLevelAngle(for: gravity, orientation: orientation)
            self.isAvailable = true

            if !self.hasInitialAngle {
                self.angle = measured
                self.hasInitialAngle = true
            } else {
                // A level line repeats every 180 degrees. Smooth using the nearest equivalent
                // angle so rotating past +/-90 degrees never makes the meter jump across screen.
                var delta = measured - self.angle
                while delta > .pi / 2 { delta -= .pi }
                while delta < -.pi / 2 { delta += .pi }
                self.angle += delta * 0.28
                while self.angle > .pi / 2 { self.angle -= .pi }
                while self.angle < -.pi / 2 { self.angle += .pi }
            }
        }
    }

    func stop() {
        motionManager.stopDeviceMotionUpdates()
        hasInitialAngle = false
        lastOrientation = nil
        isAvailable = false
    }

    private func currentInterfaceOrientation() -> UIInterfaceOrientation {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.interfaceOrientation }
            .first ?? .portrait
    }

    private func normalizedLevelAngle(for gravity: CMAcceleration, orientation: UIInterfaceOrientation) -> Double {
        let rawAngle: Double
        switch orientation {
        case .portraitUpsideDown:
            rawAngle = atan2(-gravity.x, gravity.y)
        case .landscapeLeft:
            rawAngle = atan2(-gravity.y, gravity.x)
        case .landscapeRight:
            rawAngle = atan2(gravity.y, -gravity.x)
        default:
            rawAngle = atan2(gravity.x, -gravity.y)
        }

        var result = rawAngle
        while result > .pi / 2 { result -= .pi }
        while result < -.pi / 2 { result += .pi }
        return result
    }
}
