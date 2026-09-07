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
        Button(action: {
            DiagnosticLogger.shared.action("Button pressed", metadata: ["button": accessibilityLabel])
            CameraHaptics.fire()
            action()
        }) {
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
    var isEnabled = true
    var countdown = 0
    let action: () -> Void

    var body: some View {
        Button(action: {
            DiagnosticLogger.shared.action(isRecording ? "Stop recording button pressed" : "Record button pressed")
            action()
        }) {
            ZStack {
                Circle()
                    .fill(.white)
                    .frame(width: 76, height: 76)
                RoundedRectangle(cornerRadius: isRecording ? 7 : 34)
                    .fill(.red)
                    .frame(width: isRecording ? 30 : 62, height: isRecording ? 30 : 62)
                if countdown > 0 {
                    Text("\(countdown)")
                        .font(.system(.title2, design: .rounded).weight(.bold))
                        .foregroundStyle(.white)
                }
            }
        }
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.55)
        .accessibilityLabel(countdown > 0 ? "Cancel recording countdown, \(countdown) seconds remaining" : (isRecording ? "Stop recording" : "Start recording"))
    }
}

struct PhotoButton: View {
    @Environment(\.cameraTint) private var theme
    let isCapturing: Bool
    let countdown: Int
    let countdownTotal: Int
    var isEnabled = true
    let action: () -> Void
    let onBurstStart: () -> Void
    let onBurstEnd: () -> Void
    @State private var pressTask: Task<Void, Never>?
    @State private var isPressActive = false
    @State private var isBurstActive = false
    @GestureState private var isPressGestureActive = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(.white, lineWidth: 4)
                .frame(width: 76, height: 76)
            Circle()
                .fill(.white)
                .frame(width: 62, height: 62)
                .scaleEffect(isCapturing ? 0.86 : 1)

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
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .updating($isPressGestureActive) { _, active, _ in active = true }
                .onChanged { _ in beginPress() }
                .onEnded { _ in endPress() }
        )
        .opacity(isEnabled ? 1 : 0.55)
        .accessibilityLabel("Take photo")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            guard isEnabled, !isCapturing else { return }
            DiagnosticLogger.shared.action("Photo shutter accessibility action")
            action()
        }
        .onChange(of: isEnabled) { enabled in if !enabled { cancelPress() } }
        .onChange(of: isPressGestureActive) { active in if !active { cancelPress() } }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            cancelPress()
        }
        .onDisappear { cancelPress() }
    }

    private var countdownProgress: CGFloat {
        guard countdownTotal > 0 else { return 0 }
        return max(0.04, min(CGFloat(countdown) / CGFloat(countdownTotal), 1))
    }

    private func beginPress() {
        guard isEnabled, !isCapturing, !isPressActive else { return }
        isPressActive = true
        // A press during a countdown cancels it on release; it must not start a burst.
        guard countdown == 0 else { return }
        pressTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 450_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled, isPressActive else { return }
            isBurstActive = true
            pressTask = nil
            DiagnosticLogger.shared.action("Photo shutter hold started burst")
            onBurstStart()
        }
    }

    private func endPress() {
        guard isPressActive else { return }
        let didStartBurst = isBurstActive
        pressTask?.cancel()
        pressTask = nil
        isPressActive = false
        isBurstActive = false

        if didStartBurst {
            DiagnosticLogger.shared.action("Photo burst hold released")
            onBurstEnd()
        } else if isEnabled, !isCapturing {
            DiagnosticLogger.shared.action("Photo shutter pressed")
            action()
        }
    }

    private func cancelPress() {
        pressTask?.cancel()
        pressTask = nil
        isPressActive = false
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
                    DiagnosticLogger.shared.action("Capture mode button pressed", metadata: ["mode": mode.rawValue])
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
                        DiagnosticLogger.shared.action("Exposure reset pressed")
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
                .onChange(of: isLevelMeterEnabled) { enabled in
                    DiagnosticLogger.shared.action("Level Meter toggle changed", metadata: ["enabled": String(enabled)])
                }
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
        .opacity(isAvailable ? 1 : 0)
        .animation(.easeOut(duration: 0.10), value: isLevel)
        .animation(.easeOut(duration: 0.12), value: isAvailable)
        .accessibilityHidden(!isAvailable)
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

struct CameraLevelHost: View {
    let enabled: Bool
    let isActive: Bool
    @StateObject private var monitor = CameraLevelMonitor()

    var body: some View {
        Group {
            if enabled {
                CameraLevelOverlay(
                    angle: monitor.angle,
                    isAvailable: monitor.isAvailable,
                    isLevel: monitor.isLevel
                )
                .offset(y: -8)
                .allowsHitTesting(false)
            }
        }
        // Drive monitoring from one lifecycle identity instead of relying on the order in
        // which onAppear, AppStorage restoration and scenePhase changes happen at launch.
        // A true initial value now starts Core Motion after the view is actually mounted, and
        // foreground/background changes deterministically restart/stop the same monitor.
        .task(id: enabled && isActive) {
            if enabled && isActive {
                monitor.start()
            } else {
                monitor.stop()
            }
        }
        .onDisappear { monitor.stop() }
    }
}

final class CameraLevelMonitor: ObservableObject {
    @Published private(set) var angle: Double = 0
    @Published private(set) var isAvailable = false
    @Published private(set) var levelDeviation: Double = .infinity

    private let motionManager = CMMotionManager()
    private let motionQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.swazi.LowPolyCam.level-motion"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        return queue
    }()

    private var invalidSampleCount = 0
    private let invalidSamplesBeforeHiding = 6

    // A persisted ON toggle is only considered healthy after a valid gravity sample arrives.
    // Core Motion delivery happens off-main so cold camera/session setup cannot starve the stream.
    private var wantsMonitoring = false
    private var startupGeneration: UInt64 = 0
    private var startupRetryCount = 0
    private var startupRetryWorkItem: DispatchWorkItem?
    private var healthWatchdogWorkItem: DispatchWorkItem?
    private var receivedValidSampleThisAttempt = false
    private var hasReceivedValidSample = false
    private var lastMotionDeliveryUptime: TimeInterval?

    var isLevel: Bool {
        let tolerance = 1.5 * Double.pi / 180
        return isAvailable && levelDeviation <= tolerance
    }

    func start() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.start() }
            return
        }
        guard !wantsMonitoring else {
            if !motionManager.isDeviceMotionActive && startupRetryWorkItem == nil {
                startupRetryCount = 0
                attemptStart()
            }
            return
        }

        wantsMonitoring = true
        startupRetryCount = 0
        hasReceivedValidSample = false
        attemptStart()
    }

    func stop() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.stop() }
            return
        }
        wantsMonitoring = false
        startupGeneration &+= 1
        cancelStartupRetry()
        cancelHealthWatchdog()
        motionManager.stopDeviceMotionUpdates()
        markUnavailable(resetFilter: true)
        lastMotionDeliveryUptime = nil
        hasReceivedValidSample = false
    }

    private func attemptStart() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard wantsMonitoring else { return }

        startupGeneration &+= 1
        let generation = startupGeneration
        receivedValidSampleThisAttempt = false
        lastMotionDeliveryUptime = nil
        cancelStartupRetry()
        cancelHealthWatchdog()

        guard motionManager.isDeviceMotionAvailable else {
            markUnavailable(resetFilter: true)
            scheduleStartupRetry(for: generation)
            return
        }

        if motionManager.isDeviceMotionActive {
            motionManager.stopDeviceMotionUpdates()
        }

        invalidSampleCount = 0
        motionManager.deviceMotionUpdateInterval = 1.0 / 30.0
        motionManager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: motionQueue) {
            [weak self] motion, error in
            let deliveredMotion = motion != nil
            let targetAngle: Double?
            if error == nil, let gravity = motion?.gravity {
                targetAngle = CameraLevelMath.indicatorAngle(
                    gravityX: gravity.x,
                    gravityY: gravity.y
                )
            } else {
                targetAngle = nil
            }

            DispatchQueue.main.async { [weak self] in
                self?.handleMotionDelivery(
                    generation: generation,
                    deliveredMotion: deliveredMotion,
                    targetAngle: targetAngle
                )
            }
        }

        scheduleStartupRetry(for: generation)
    }

    private func handleMotionDelivery(
        generation: UInt64,
        deliveredMotion: Bool,
        targetAngle: Double?
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard wantsMonitoring, startupGeneration == generation else { return }

        if deliveredMotion {
            lastMotionDeliveryUptime = ProcessInfo.processInfo.systemUptime
        }

        guard let targetAngle else {
            noteInvalidSample()
            return
        }

        // Do not cancel launch recovery merely because Core Motion emitted an object. A real,
        // finite gravity-derived angle proves the stream is useful and the Level toggle is ON.
        receivedValidSampleThisAttempt = true
        hasReceivedValidSample = true
        cancelStartupRetry()
        scheduleHealthWatchdog(for: generation)

        invalidSampleCount = 0
        let nextAngle = isAvailable
            ? CameraLevelMath.smooth(current: angle, target: targetAngle)
            : targetAngle
        let nextDeviation = abs(nextAngle)
        if abs(angle - nextAngle) > 0.0005 { angle = nextAngle }
        if abs(levelDeviation - nextDeviation) > 0.0005 { levelDeviation = nextDeviation }
        if !isAvailable { isAvailable = true }
    }

    private func scheduleStartupRetry(for generation: UInt64) {
        guard CameraLevelLifecyclePolicy.shouldRetryStartup(
            wantsMonitoring: wantsMonitoring,
            receivedValidSample: receivedValidSampleThisAttempt,
            retryCount: startupRetryCount
        ) else { return }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.wantsMonitoring,
                  self.startupGeneration == generation,
                  !self.receivedValidSampleThisAttempt else { return }

            self.startupRetryWorkItem = nil
            self.startupRetryCount += 1
            if self.motionManager.isDeviceMotionActive {
                self.motionManager.stopDeviceMotionUpdates()
            }
            self.attemptStart()
        }
        startupRetryWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + CameraLevelLifecyclePolicy.startupRetryDelay,
            execute: workItem
        )
    }

    private func scheduleHealthWatchdog(for generation: UInt64) {
        guard wantsMonitoring, hasReceivedValidSample else { return }
        cancelHealthWatchdog()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.wantsMonitoring,
                  self.startupGeneration == generation,
                  self.hasReceivedValidSample else { return }

            self.healthWatchdogWorkItem = nil
            let now = ProcessInfo.processInfo.systemUptime
            if !CameraLevelLifecyclePolicy.streamIsStale(
                now: now,
                lastDelivery: self.lastMotionDeliveryUptime
            ) {
                self.scheduleHealthWatchdog(for: generation)
                return
            }

            // isDeviceMotionActive can remain true for a silent stream. Hide stale UI and perform
            // one bounded launch-style recovery; the existing valid angle is preserved for resume.
            self.markUnavailable(resetFilter: false)
            self.startupRetryCount = 0
            self.hasReceivedValidSample = false
            if self.motionManager.isDeviceMotionActive {
                self.motionManager.stopDeviceMotionUpdates()
            }
            self.attemptStart()
        }
        healthWatchdogWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + CameraLevelLifecyclePolicy.healthCheckInterval,
            execute: workItem
        )
    }

    private func cancelStartupRetry() {
        startupRetryWorkItem?.cancel()
        startupRetryWorkItem = nil
    }

    private func cancelHealthWatchdog() {
        healthWatchdogWorkItem?.cancel()
        healthWatchdogWorkItem = nil
    }

    private func noteInvalidSample() {
        invalidSampleCount += 1
        // A single transient miss must not visibly snap the indicator to horizontal. If the phone
        // points nearly straight up/down for a sustained interval, roll is undefined; hide the
        // meter while preserving the last valid angle for a clean resume.
        if invalidSampleCount >= invalidSamplesBeforeHiding {
            markUnavailable(resetFilter: false)
        }
    }

    private func markUnavailable(resetFilter: Bool) {
        // Hide first so resetting internal state can never flash a fake horizontal "level" line.
        if isAvailable { isAvailable = false }
        levelDeviation = .infinity
        if resetFilter {
            invalidSampleCount = 0
            angle = 0
        }
    }
}

