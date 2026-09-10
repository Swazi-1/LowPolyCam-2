import Combine
import Foundation

final class RecordingClockState: ObservableObject {
    @Published private(set) var elapsedSeconds: TimeInterval = 0

    private var startUptime: TimeInterval?
    private var pausedAtUptime: TimeInterval?
    private var timer: Timer?
    private let uptimeProvider: () -> TimeInterval

    init(uptimeProvider: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.uptimeProvider = uptimeProvider
    }

    deinit {
        timer?.invalidate()
    }

    func startIfNeeded() {
        if startUptime == nil {
            startUptime = uptimeProvider()
            if elapsedSeconds != 0 { elapsedSeconds = 0 }
            AppEventLog.deepEvent("RECORDING CLOCK START", category: .recording)
        }

        update()
        guard pausedAtUptime == nil, timer == nil else { return }

        startTimer()
    }

    func pause() {
        guard startUptime != nil, pausedAtUptime == nil else { return }
        update()
        pausedAtUptime = uptimeProvider()
        timer?.invalidate()
        timer = nil
        AppEventLog.deepEvent("RECORDING CLOCK PAUSE", category: .recording,
                              fields: ["elapsedSeconds": String(format: "%.0f", elapsedSeconds)])
    }

    func resume() {
        guard let startUptime, let pausedAtUptime else { return }
        let now = uptimeProvider()
        self.startUptime = startUptime + max(0, now - pausedAtUptime)
        self.pausedAtUptime = nil
        update()
        guard timer == nil else { return }

        startTimer()
        AppEventLog.deepEvent("RECORDING CLOCK RESUME", category: .recording,
                              fields: ["elapsedSeconds": String(format: "%.0f", elapsedSeconds)])
    }

    private func startTimer() {
        guard timer == nil else { return }

        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.update()
        }
        timer.tolerance = 0.1
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stopAndReset() {
        let previousElapsed = elapsedSeconds
        timer?.invalidate()
        timer = nil
        startUptime = nil
        pausedAtUptime = nil
        if elapsedSeconds != 0 { elapsedSeconds = 0 }
        AppEventLog.deepEvent("RECORDING CLOCK RESET", category: .recording,
                              fields: ["previousElapsedSeconds": String(format: "%.0f", previousElapsed)])
    }

    func update() {
        guard let startUptime else { return }
        let currentUptime = pausedAtUptime ?? uptimeProvider()
        let elapsed = floor(max(0, currentUptime - startUptime))
        if elapsed != elapsedSeconds { elapsedSeconds = elapsed }
    }
}
