import AVFoundation
import CoreVideo
import Foundation

/// Measures the capture callback stream. Extreme diagnostics can temporarily inspect every callback
/// around a zoom/lens transition to catch one-frame zoom-factor resets without logging every frame
/// during normal camera use.
final class LiveCaptureMetrics: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let output = AVCaptureVideoDataOutput()
    let queue = DispatchQueue(label: "com.swazi.lowpolycam.liveMetrics", qos: .utility)
    private let lock = NSLock()
    private var running = false
    private var first: Double?
    private var latest: Double?
    private var intervals = 0
    private var dropped = 0
    private var previousFrameTimestamp: Double?

    private var zebraEnabled = false
    private var zebraGeneration = 0
    private var zebraPixelFormatLoggedGeneration = -1
    private var zebraLastAnalysisUptime: TimeInterval = 0
    private var zebraHandler: ((ZebraMask) -> Void)?
    private var configuredZebraPixelFormat: OSType?

    private weak var probeDevice: AVCaptureDevice?
    private var probeTraceID: String?
    private var probeExpectedDeviceZoom: CGFloat = 1
    private var probeExpectedDisplayedZoom: CGFloat = 1
    private var probeHUDZoom = ""
    private var probeUntilUptime: TimeInterval = 0
    private var probeFrameIndex = 0
    private var probeAnomalyFrames = 0
    private var probeLastActualZoom: CGFloat?
    private var probeLastLuma: Double?

    override init() {
        super.init()
        output.alwaysDiscardsLateVideoFrames = true
        output.automaticallyConfiguresOutputBufferDimensions = false
        output.deliversPreviewSizedOutputBuffers = true
        let preferredPixelFormats: [OSType] = [
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelFormatType_32BGRA
        ]
        if let pixelFormat = preferredPixelFormats.first(where: { output.availableVideoPixelFormatTypes.contains($0) }) {
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: pixelFormat]
            configuredZebraPixelFormat = pixelFormat
        }
        output.setSampleBufferDelegate(self, queue: queue)
    }

    func setRunning(_ value: Bool) {
        lock.lock()
        running = value
        first = nil
        latest = nil
        intervals = 0
        dropped = 0
        previousFrameTimestamp = nil
        lock.unlock()
        AppEventLog.deepEvent("LIVE CAPTURE METRICS STATE", category: .performance, fields: ["running": String(value)])
    }

    func setZebraAnalysis(enabled: Bool, handler: ((ZebraMask) -> Void)? = nil) {
        lock.lock()
        zebraEnabled = enabled
        zebraGeneration += 1
        zebraPixelFormatLoggedGeneration = -1
        zebraLastAnalysisUptime = 0
        zebraHandler = enabled ? handler : nil
        lock.unlock()
        if !enabled { handler?(.empty) }
        AppEventLog.deepEvent("ZEBRA ANALYSIS CONFIG", category: .exposure, fields: [
            "enabled": String(enabled),
            "configuredPixelFormat": configuredZebraPixelFormat.map { ZebraExposureAnalyzer.pixelFormatName($0) } ?? "automatic",
            "thresholdNormalized": "0.98",
            "grid": "24x16",
            "analysisIntervalMs": "75"
        ])
    }

    func beginZoomTransitionProbe(
        traceID: String,
        device: AVCaptureDevice,
        expectedDeviceZoom: CGFloat,
        expectedDisplayedZoom: CGFloat,
        hudZoom: String,
        duration: TimeInterval = 1.25
    ) {
        guard AppEventLog.extremeDiagnosticsEnabled else { return }
        lock.lock()
        probeDevice = device
        probeTraceID = traceID
        probeExpectedDeviceZoom = expectedDeviceZoom
        probeExpectedDisplayedZoom = expectedDisplayedZoom
        probeHUDZoom = hudZoom
        probeUntilUptime = ProcessInfo.processInfo.systemUptime + max(duration, 0.25)
        probeFrameIndex = 0
        probeAnomalyFrames = 0
        probeLastActualZoom = nil
        probeLastLuma = nil
        lock.unlock()
        AppEventLog.deepEvent("FRAME-LEVEL ZOOM PROBE START", category: .zoom, traceID: traceID, fields: [
            "device": device.localizedName,
            "expectedDeviceZoom": String(format: "%.3f", Double(expectedDeviceZoom)),
            "expectedDisplayedZoom": String(format: "%.3f", Double(expectedDisplayedZoom)),
            "hudZoom": hudZoom,
            "durationMs": String(format: "%.0f", duration * 1000)
        ])
    }

    func updateZoomTransitionProbe(
        traceID: String,
        device: AVCaptureDevice,
        expectedDeviceZoom: CGFloat,
        expectedDisplayedZoom: CGFloat,
        hudZoom: String
    ) {
        guard AppEventLog.extremeDiagnosticsEnabled else { return }
        lock.lock()
        guard probeTraceID == traceID else { lock.unlock(); return }
        probeDevice = device
        probeExpectedDeviceZoom = expectedDeviceZoom
        probeExpectedDisplayedZoom = expectedDisplayedZoom
        probeHUDZoom = hudZoom
        probeUntilUptime = max(probeUntilUptime, ProcessInfo.processInfo.systemUptime + 0.6)
        lock.unlock()
        AppEventLog.deepEvent("FRAME-LEVEL ZOOM PROBE TARGET UPDATED", category: .zoom, traceID: traceID, fields: [
            "device": device.localizedName,
            "expectedDeviceZoom": String(format: "%.3f", Double(expectedDeviceZoom)),
            "expectedDisplayedZoom": String(format: "%.3f", Double(expectedDisplayedZoom)),
            "hudZoom": hudZoom
        ])
    }

    /// Moves an active probe to the device that actually owns the capture stream after a
    /// physical lens handoff. Reset the frame-to-frame baselines because the old and new
    /// devices are separate sensors; otherwise the first callback after the swap can be
    /// compared with stale zoom/luma state and reported as a flicker.
    func retargetZoomTransitionProbe(
        traceID: String,
        device: AVCaptureDevice,
        expectedDeviceZoom: CGFloat,
        expectedDisplayedZoom: CGFloat,
        hudZoom: String,
        reason: String
    ) {
        guard AppEventLog.extremeDiagnosticsEnabled else { return }
        lock.lock()
        guard probeTraceID == traceID else { lock.unlock(); return }
        probeDevice = device
        probeExpectedDeviceZoom = expectedDeviceZoom
        probeExpectedDisplayedZoom = expectedDisplayedZoom
        probeHUDZoom = hudZoom
        probeUntilUptime = max(probeUntilUptime, ProcessInfo.processInfo.systemUptime + 0.6)
        probeLastActualZoom = nil
        probeLastLuma = nil
        lock.unlock()
        AppEventLog.deepEvent("FRAME-LEVEL ZOOM PROBE RETARGETED", category: .zoom, traceID: traceID, fields: [
            "reason": reason,
            "device": device.localizedName,
            "expectedDeviceZoom": String(format: "%.3f", Double(expectedDeviceZoom)),
            "expectedDisplayedZoom": String(format: "%.3f", Double(expectedDisplayedZoom)),
            "hudZoom": hudZoom
        ])
    }

    func endZoomTransitionProbe(traceID: String, reason: String) {
        lock.lock()
        guard probeTraceID == traceID else { lock.unlock(); return }
        let frames = probeFrameIndex
        let anomalies = probeAnomalyFrames
        probeTraceID = nil
        probeDevice = nil
        probeUntilUptime = 0
        lock.unlock()
        AppEventLog.deepEvent("FRAME-LEVEL ZOOM PROBE END", category: .zoom, traceID: traceID, fields: [
            "reason": reason,
            "framesObserved": String(frames),
            "anomalyFrames": String(anomalies)
        ])
    }

    func read() -> (fps: Double?, drops: Int) {
        lock.lock()
        defer { lock.unlock() }
        let elapsed = (latest ?? 0) - (first ?? 0)
        let fps = elapsed > 0 && intervals > 0 ? Double(intervals) / elapsed : nil
        first = latest
        intervals = 0
        return (fps, dropped)
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        guard timestamp.isFinite else { return }

        var zebraConfiguration: (generation: Int, handler: (ZebraMask) -> Void)?
        var zebraPixelFormatToLog: (generation: Int, pixelFormat: OSType, width: Int, height: Int, mirrored: Bool, rotation: CGFloat)?
        var probeRecord: (trace: String, frame: Int, device: String, actual: CGFloat, expected: CGFloat, expectedDisplayed: CGFloat, hud: String, delta: CGFloat, frameGapMs: Double?, luma: Double?, lumaDelta: Double?, zoomAnomaly: Bool, brightnessFlicker: Bool, anomaly: Bool)?
        var expiredProbe: (trace: String, frames: Int, anomalies: Int)?

        lock.lock()
        let now = ProcessInfo.processInfo.systemUptime
        let probeActive = probeTraceID != nil && now <= probeUntilUptime
        if running {
            if first == nil { first = timestamp } else { intervals += 1 }
            latest = timestamp
        }

        if zebraEnabled, now - zebraLastAnalysisUptime >= 0.075, let handler = zebraHandler {
            zebraLastAnalysisUptime = now
            zebraConfiguration = (zebraGeneration, handler)
            if zebraPixelFormatLoggedGeneration != zebraGeneration,
               let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
                zebraPixelFormatLoggedGeneration = zebraGeneration
                zebraPixelFormatToLog = (
                    zebraGeneration,
                    CVPixelBufferGetPixelFormatType(imageBuffer),
                    CVPixelBufferGetWidth(imageBuffer),
                    CVPixelBufferGetHeight(imageBuffer),
                    connection.isVideoMirrored,
                    connection.videoRotationAngle
                )
            }
        }

        if probeActive, let trace = probeTraceID, let device = probeDevice {
            probeFrameIndex += 1
            let actual = device.videoZoomFactor
            let expected = probeExpectedDeviceZoom
            let delta = abs(actual - expected)
            let jumped = probeLastActualZoom.map { abs(actual - $0) > 0.35 } ?? false
            let zoomAnomaly = delta > max(0.08, expected * 0.05) || jumped
            let luma = Self.sparseLuma(sampleBuffer)
            let lumaDelta = luma.flatMap { value in probeLastLuma.map { abs(value - $0) } }
            // Luma is an 8-bit sample average. A >28-point one-frame jump is intentionally a
            // conservative "possible flicker" marker; it is evidence, not proof, because the user
            // may also have moved across a very bright/dark edge during the transition.
            let brightnessFlicker = lumaDelta.map { $0 > 28.0 } ?? false
            let anomaly = zoomAnomaly || brightnessFlicker
            if anomaly { probeAnomalyFrames += 1 }
            let gapMs = previousFrameTimestamp.map { max(0, timestamp - $0) * 1000 }
            // Extreme Bug Trace logs every observed frame while the bounded transition probe is
            // active. Normal diagnostics keep the original first-20/anomaly-only behavior.
            if AppEventLog.extremeDiagnosticsEnabled || probeFrameIndex <= 20 || anomaly {
                probeRecord = (trace, probeFrameIndex, device.localizedName, actual, expected,
                               probeExpectedDisplayedZoom, probeHUDZoom, delta, gapMs, luma, lumaDelta,
                               zoomAnomaly, brightnessFlicker, anomaly)
            }
            probeLastActualZoom = actual
            if let luma { probeLastLuma = luma }
        } else if let trace = probeTraceID, now > probeUntilUptime {
            expiredProbe = (trace, probeFrameIndex, probeAnomalyFrames)
            probeTraceID = nil
            probeDevice = nil
            probeUntilUptime = 0
        }
        previousFrameTimestamp = timestamp
        lock.unlock()

        if let zebraPixelFormatToLog {
            AppEventLog.event("ZEBRA PIXEL FORMAT", category: .exposure, fields: [
                "generation": String(zebraPixelFormatToLog.generation),
                "pixelFormat": ZebraExposureAnalyzer.pixelFormatName(zebraPixelFormatToLog.pixelFormat),
                "width": String(zebraPixelFormatToLog.width),
                "height": String(zebraPixelFormatToLog.height),
                "mirrored": String(zebraPixelFormatToLog.mirrored),
                "rotationAngle": String(format: "%.1f", Double(zebraPixelFormatToLog.rotation)),
                "configuredPixelFormat": configuredZebraPixelFormat.map(ZebraExposureAnalyzer.pixelFormatName) ?? "automatic"
            ])
        }

        if let zebraConfiguration {
            let mask = ZebraExposureAnalyzer.analyze(sampleBuffer: sampleBuffer, connection: connection)
            lock.lock()
            let stillCurrent = zebraEnabled && zebraGeneration == zebraConfiguration.generation
            lock.unlock()
            if stillCurrent { zebraConfiguration.handler(mask) }
        }

        if let record = probeRecord {
            let fields: [String: String] = [
                "frame": String(record.frame),
                "device": record.device,
                "actualDeviceZoom": String(format: "%.3f", Double(record.actual)),
                "expectedDeviceZoom": String(format: "%.3f", Double(record.expected)),
                "expectedDisplayedZoom": String(format: "%.3f", Double(record.expectedDisplayed)),
                "hudZoom": record.hud,
                "zoomDelta": String(format: "%.3f", Double(record.delta)),
                "frameGapMs": record.frameGapMs.map { String(format: "%.2f", $0) } ?? "first",
                "meanLuma8bit": record.luma.map { String(format: "%.2f", $0) } ?? "unavailable",
                "lumaDelta": record.lumaDelta.map { String(format: "%.2f", $0) } ?? "first",
                "zoomAnomaly": String(record.zoomAnomaly),
                "brightnessFlicker": String(record.brightnessFlicker),
                "pts": String(format: "%.6f", timestamp)
            ]
            if record.anomaly {
                AppEventLog.event("!!! POSSIBLE VISIBLE ZOOM/LENS FLICKER !!!", category: .zoom, level: .warning,
                                  traceID: record.trace, fields: fields)
            } else {
                AppEventLog.deepEvent("ZOOM TRANSITION FRAME", category: .zoom, traceID: record.trace, fields: fields)
            }
        }
        if let expiredProbe {
            AppEventLog.deepEvent("FRAME-LEVEL ZOOM PROBE EXPIRED", category: .zoom, traceID: expiredProbe.trace, fields: [
                "framesObserved": String(expiredProbe.frames),
                "anomalyFrames": String(expiredProbe.anomalies)
            ])
        }
    }

    /// Samples a tiny grid from the luma plane during the short transition probe. It avoids a full
    /// image conversion/analysis pass while still giving diagnostics evidence for a one-frame
    /// brightness flash caused by exposure/lens/ISP settling.
    private static func sparseLuma(_ sampleBuffer: CMSampleBuffer) -> Double? {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let plane: Int
        let width: Int
        let height: Int
        let bytesPerRow: Int
        let base: UnsafeMutableRawPointer?
        if CVPixelBufferIsPlanar(pixelBuffer), CVPixelBufferGetPlaneCount(pixelBuffer) > 0 {
            plane = 0
            width = CVPixelBufferGetWidthOfPlane(pixelBuffer, plane)
            height = CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
            bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane)
            base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane)
        } else {
            plane = -1
            width = CVPixelBufferGetWidth(pixelBuffer)
            height = CVPixelBufferGetHeight(pixelBuffer)
            bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
            base = CVPixelBufferGetBaseAddress(pixelBuffer)
        }
        guard width > 0, height > 0, bytesPerRow > 0, let base else { return nil }

        let ptr = base.assumingMemoryBound(to: UInt8.self)
        let sampleColumns = 16
        let sampleRows = 12
        var total: UInt64 = 0
        var count: UInt64 = 0
        for row in 0..<sampleRows {
            let y = min(height - 1, ((row * 2 + 1) * height) / (sampleRows * 2))
            for column in 0..<sampleColumns {
                let x = min(width - 1, ((column * 2 + 1) * width) / (sampleColumns * 2))
                // Video-data output is normally bi-planar 4:2:0, whose first plane is one-byte
                // luma. For a non-planar fallback, sampling the first byte still remains diagnostic
                // only and never affects capture output.
                total += UInt64(ptr[y * bytesPerRow + x])
                count += 1
            }
        }
        return count > 0 ? Double(total) / Double(count) : nil
    }

    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        var trace: String?
        var dropNumber = 0
        lock.lock()
        if running {
            dropped += 1
            dropNumber = dropped
        }
        if probeTraceID != nil, ProcessInfo.processInfo.systemUptime <= probeUntilUptime {
            trace = probeTraceID
        }
        lock.unlock()

        // Extreme mode records every dropped diagnostics callback so short bursts cannot disappear.
        // Keep these at TRACE: AVCaptureVideoDataOutput intentionally discards late diagnostic
        // frames and this does not by itself mean the movie-file output lost encoded frames.
        if AppEventLog.extremeDiagnosticsEnabled && (trace != nil || dropNumber > 0) {
            AppEventLog.deepEvent("CAPTURE CALLBACK FRAME DROPPED", category: .performance, traceID: trace, fields: [
                "dropNumber": String(dropNumber),
                "pts": timestamp.isFinite ? String(format: "%.6f", timestamp) : "invalid"
            ])
        }
    }
}
