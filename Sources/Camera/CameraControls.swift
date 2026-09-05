import SwiftUI
import Foundation

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

import SwiftUI
import CoreMotion
import UIKit

struct ProToolsPopup: View {
    @ObservedObject var camera: CameraManager
    @StateObject private var levelMonitor = LevelMonitor()

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

            HStack {
                Text("White Balance")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Picker("White Balance", selection: Binding(
                    get: { camera.whiteBalancePreset },
                    set: { camera.selectWhiteBalancePreset($0) }
                )) {
                    ForEach(CameraManager.WhiteBalancePreset.allCases) { preset in
                        Text(preset.rawValue).tag(preset)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .tint(.yellow)
            }

            Divider()
                .overlay(.white.opacity(0.15))

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Level")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(levelMonitor.statusText)
                        .font(.system(.caption, design: .monospaced).weight(.semibold))
                        .foregroundStyle(levelMonitor.isLevel ? .green : .white.opacity(0.7))
                }

                LevelMeterView(angle: levelMonitor.angle, isLevel: levelMonitor.isLevel)
            }
        }
        .foregroundStyle(.white)
        .padding(16)
        .frame(width: 260)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.white.opacity(0.12), lineWidth: 1)
        }
        .onAppear { levelMonitor.start() }
        .onDisappear { levelMonitor.stop() }
    }

    private var evLabel: String {
        abs(camera.exposureBias) < 0.05 ? "0.0" : String(format: "%+.1f", camera.exposureBias)
    }
}

private struct LevelMeterView: View {
    let angle: Double
    let isLevel: Bool

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Capsule()
                    .fill(.white.opacity(0.18))
                    .frame(height: 2)

                Capsule()
                    .fill(isLevel ? .green : .yellow)
                    .frame(width: min(proxy.size.width * 0.62, 130), height: 3)
                    .rotationEffect(.radians(angle))

                Circle()
                    .fill(.white)
                    .frame(width: 5, height: 5)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        }
        .frame(height: 38)
    }
}

private final class LevelMonitor: ObservableObject {
    @Published private(set) var angle: Double = 0
    @Published private(set) var isAvailable = false

    private let motionManager = CMMotionManager()

    var degrees: Double { angle * 180 / .pi }
    var isLevel: Bool { isAvailable && abs(degrees) <= 1.5 }

    var statusText: String {
        guard isAvailable else { return "—" }
        return isLevel ? "LEVEL" : String(format: "%+.1f°", degrees)
    }

    func start() {
        guard motionManager.isDeviceMotionAvailable else {
            isAvailable = false
            return
        }

        motionManager.deviceMotionUpdateInterval = 1.0 / 12.0
        motionManager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let gravity = motion?.gravity else { return }
            let flatness = hypot(gravity.x, gravity.y)
            guard flatness > 0.18 else {
                self.isAvailable = false
                return
            }

            self.isAvailable = true
            self.angle = self.normalizedLevelAngle(for: gravity)
        }
    }

    func stop() {
        motionManager.stopDeviceMotionUpdates()
    }

    private func normalizedLevelAngle(for gravity: CMAcceleration) -> Double {
        let orientation = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.interfaceOrientation }
            .first ?? .portrait

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

