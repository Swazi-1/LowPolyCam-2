import Foundation

struct StorageSnapshot: Equatable {
    let availableBytes: Int64
    let isWarning: Bool
    let isCritical: Bool
    let checkedAt: Date
}

/// Performs the small amount of filesystem work needed for the storage HUD and recording
/// protection without putting disk queries on the main or camera session queues.
final class StorageGuard {
    static let warningThresholdBytes: Int64 = 1_000_000_000
    static let minimumCriticalReserveBytes: Int64 = 300 * 1_024 * 1_024
    static let extraSafetyMarginBytes: Int64 = 128 * 1_024 * 1_024

    private let queue = DispatchQueue(label: "com.swazi.lowpolycam.storageGuard", qos: .utility)
    private var monitorTimer: DispatchSourceTimer?
    private var monitorGeneration: UInt64 = 0
    private var isMonitoring = false
    private var criticalReserveBytes = StorageGuard.minimumCriticalReserveBytes
    private var monitorCallback: ((StorageSnapshot) -> Void)?
    private var monitorTick: UInt64 = 0
    private var lastLoggedWarning: Bool?
    private var lastLoggedCritical: Bool?

    /// Keeps enough room for movie finalization and Photos/recovery metadata. The absolute floor
    /// prevents a recording from running the volume down to an unsafe near-zero amount.
    static func criticalReserveBytes(forVideoBitrate bitsPerSecond: Double) -> Int64 {
        let bitrate = max(bitsPerSecond, 2_000_000)
        let twentySecondsOfVideo = Int64((bitrate * 20.0 / 8.0).rounded(.up))
        return max(
            minimumCriticalReserveBytes,
            twentySecondsOfVideo + extraSafetyMarginBytes
        )
    }

    func checkNow(
        criticalReserveBytes: Int64,
        completion: @escaping (StorageSnapshot?) -> Void
    ) {
        let traceID = AppEventLog.extremeDiagnosticsEnabled ? AppEventLog.makeTraceID("STORAGE-CHECK") : nil
        let scheduledAt = ProcessInfo.processInfo.systemUptime
        AppEventLog.deepEvent("STORAGE CHECK QUEUED", category: .storage, traceID: traceID,
                              fields: ["criticalReserveBytes": String(criticalReserveBytes)])
        queue.async { [weak self] in
            guard let self else { return }
            let startedAt = ProcessInfo.processInfo.systemUptime
            let snapshot = self.readSnapshot(criticalReserveBytes: criticalReserveBytes)
            AppEventLog.deepEvent("STORAGE CHECK COMPLETE", category: .storage, traceID: traceID, fields: [
                "queueWaitMs": String(format: "%.2f", (startedAt - scheduledAt) * 1000),
                "workMs": String(format: "%.2f", (ProcessInfo.processInfo.systemUptime - startedAt) * 1000),
                "availableBytes": snapshot.map { String($0.availableBytes) } ?? "unavailable",
                "warning": snapshot.map { String($0.isWarning) } ?? "unknown",
                "critical": snapshot.map { String($0.isCritical) } ?? "unknown"
            ])
            completion(snapshot)
        }
    }

    func startMonitoring(
        criticalReserveBytes: Int64,
        onSnapshot: @escaping (StorageSnapshot) -> Void
    ) {
        queue.async { [weak self] in
            guard let self else { return }

            self.monitorGeneration &+= 1
            let generation = self.monitorGeneration
            self.criticalReserveBytes = max(criticalReserveBytes, Self.minimumCriticalReserveBytes)
            self.monitorCallback = onSnapshot
            self.monitorTimer?.cancel()
            self.isMonitoring = true
            self.monitorTick = 0
            self.lastLoggedWarning = nil
            self.lastLoggedCritical = nil
            AppEventLog.deepEvent("STORAGE MONITOR START", category: .storage, fields: [
                "generation": String(generation),
                "criticalReserveBytes": String(self.criticalReserveBytes)
            ])

            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(
                deadline: .now(),
                repeating: .seconds(1),
                leeway: .milliseconds(200)
            )
            timer.setEventHandler { [weak self] in
                self?.performMonitorCheck(generation: generation)
            }
            self.monitorTimer = timer
            timer.resume()
            self.performMonitorCheck(generation: generation)
        }
    }

    func stopMonitoring() {
        queue.async { [weak self] in
            guard let self else { return }
            self.monitorGeneration &+= 1
            self.isMonitoring = false
            self.monitorCallback = nil
            self.monitorTimer?.cancel()
            self.monitorTimer = nil
            AppEventLog.deepEvent("STORAGE MONITOR STOP", category: .storage,
                                  fields: ["generation": String(self.monitorGeneration)])
        }
    }

    deinit {
        monitorTimer?.cancel()
    }

    private func performMonitorCheck(generation: UInt64) {
        guard isMonitoring, generation == monitorGeneration else {
            AppEventLog.deepEvent("STORAGE MONITOR TICK DROPPED", category: .storage,
                                  fields: ["requestedGeneration": String(generation), "currentGeneration": String(monitorGeneration)])
            return
        }
        guard let snapshot = readSnapshot(criticalReserveBytes: criticalReserveBytes) else {
            AppEventLog.event("STORAGE MONITOR READ FAILED", category: .storage, level: .warning)
            return
        }
        monitorTick &+= 1
        let stateChanged = lastLoggedWarning != snapshot.isWarning || lastLoggedCritical != snapshot.isCritical
        if AppEventLog.extremeDiagnosticsEnabled && (stateChanged || monitorTick == 1 || monitorTick % 5 == 0) {
            AppEventLog.deepEvent("STORAGE MONITOR SNAPSHOT", category: .storage, fields: [
                "tick": String(monitorTick),
                "availableBytes": String(snapshot.availableBytes),
                "warning": String(snapshot.isWarning),
                "critical": String(snapshot.isCritical),
                "reserveBytes": String(criticalReserveBytes)
            ])
        }
        if snapshot.isCritical && lastLoggedCritical != true {
            AppEventLog.event("STORAGE CRITICAL", category: .storage, level: .warning,
                              fields: ["availableBytes": String(snapshot.availableBytes), "reserveBytes": String(criticalReserveBytes)])
        }
        lastLoggedWarning = snapshot.isWarning
        lastLoggedCritical = snapshot.isCritical
        monitorCallback?(snapshot)
    }

    private func readSnapshot(criticalReserveBytes: Int64) -> StorageSnapshot? {
        let homeURL = URL(fileURLWithPath: NSHomeDirectory())
        guard let values = try? homeURL.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ), let available = values.volumeAvailableCapacityForImportantUsage else {
            return nil
        }

        let bytes = max(available, 0)
        let reserve = max(criticalReserveBytes, Self.minimumCriticalReserveBytes)
        return StorageSnapshot(
            availableBytes: bytes,
            isWarning: bytes < Self.warningThresholdBytes,
            isCritical: bytes <= reserve,
            checkedAt: Date()
        )
    }
}
