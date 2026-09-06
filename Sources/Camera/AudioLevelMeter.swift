import AVFoundation
import AudioToolbox
import Foundation

/// Lightweight microphone level reader for the in-camera recording HUD.
/// It is independent from the movie writer, so it never changes the selected video codec.
final class AudioLevelMeter: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    let output = AVCaptureAudioDataOutput()
    // Keep meter work responsive even while the video encoder is busy. This queue only samples a
    // small fraction of the PCM values, so userInitiated QoS is still very cheap.
    private let queue = DispatchQueue(label: "com.swazi.lowpolycam.audioMeter", qos: .userInitiated)
    private let lock = NSLock()
    private var running = false
    private var level: CGFloat = 0
    private var lastLevelUpdateTime: TimeInterval = 0
    private var publishTimer: DispatchSourceTimer?

    override init() {
        super.init()
        output.setSampleBufferDelegate(self, queue: queue)
    }

    func startPublishing(every interval: DispatchTimeInterval = .milliseconds(90), onLevel: @escaping (CGFloat) -> Void) {
        stop()

        lock.lock()
        running = true
        level = 0
        lastLevelUpdateTime = ProcessInfo.processInfo.systemUptime
        lock.unlock()

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: interval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let currentLevel = self.level
            let isRunning = self.running
            self.lock.unlock()
            if isRunning { onLevel(currentLevel) }
        }
        publishTimer = timer
        timer.resume()
    }

    func stop() {
        publishTimer?.cancel()
        publishTimer = nil

        lock.lock()
        running = false
        level = 0
        lastLevelUpdateTime = 0
        lock.unlock()
    }

    deinit {
        publishTimer?.cancel()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        lock.lock()
        let shouldMeasure = running
        lock.unlock()
        guard shouldMeasure,
              let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer),
              let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else { return }

        var lengthAtOffset = 0
        var totalLength = 0
        var bytes: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: &lengthAtOffset,
            totalLengthOut: &totalLength,
            dataPointerOut: &bytes
        ) == kCMBlockBufferNoErr,
        let bytes,
        totalLength > 0 else { return }

        let normalized: CGFloat?
        if lengthAtOffset >= totalLength {
            // Fast path used by the normal iPhone microphone layout.
            normalized = meterLevel(
                from: UnsafeRawBufferPointer(start: bytes, count: totalLength),
                format: streamDescription.pointee
            )
        } else {
            // Some devices expose a segmented CMBlockBuffer. Reading only lengthAtOffset made the
            // old meter artificially weak (or completely silent). Copy the tiny audio buffer only
            // on that uncommon path so every segment contributes to the measurement.
            var contiguous = Data(count: totalLength)
            let copyStatus: OSStatus = contiguous.withUnsafeMutableBytes { destination in
                guard let base = destination.baseAddress else { return OSStatus(-1) }
                return CMBlockBufferCopyDataBytes(
                    blockBuffer,
                    atOffset: 0,
                    dataLength: totalLength,
                    destination: base
                )
            }
            guard copyStatus == kCMBlockBufferNoErr else { return }
            normalized = contiguous.withUnsafeBytes {
                meterLevel(from: $0, format: streamDescription.pointee)
            }
        }

        guard let normalized else { return }
        apply(normalized)
    }

    private func meterLevel(
        from rawBytes: UnsafeRawBufferPointer,
        format: AudioStreamBasicDescription
    ) -> CGFloat? {
        guard rawBytes.count > 0, format.mFormatID == kAudioFormatLinearPCM else { return nil }

        let bitsPerChannel = Int(format.mBitsPerChannel)
        let flags = format.mFormatFlags
        let isFloat = (flags & kAudioFormatFlagIsFloat) != 0
        let isSignedInteger = (flags & kAudioFormatFlagIsSignedInteger) != 0

        var squaredTotal = 0.0
        var peak = 0.0
        var sampleCount = 0

        func collect(_ value: Double) {
            guard value.isFinite else { return }
            let clamped = min(max(value, -1), 1)
            squaredTotal += clamped * clamped
            peak = max(peak, abs(clamped))
            sampleCount += 1
        }

        // Sampling every few PCM values is more than enough for a four-bar HUD meter and keeps
        // this output essentially free next to 4K60 / HFR recording.
        if isFloat && bitsPerChannel == 32 {
            let samples = rawBytes.bindMemory(to: Float32.self)
            for index in stride(from: 0, to: samples.count, by: 6) {
                collect(Double(samples[index]))
            }
        } else if isFloat && bitsPerChannel == 64 {
            let samples = rawBytes.bindMemory(to: Float64.self)
            for index in stride(from: 0, to: samples.count, by: 6) {
                collect(samples[index])
            }
        } else if !isFloat && bitsPerChannel == 32 {
            let samples = rawBytes.bindMemory(to: Int32.self)
            let divisor = 2_147_483_648.0
            for index in stride(from: 0, to: samples.count, by: 6) {
                collect(Double(samples[index]) / divisor)
            }
        } else if !isFloat && bitsPerChannel == 16 {
            let samples = rawBytes.bindMemory(to: Int16.self)
            for index in stride(from: 0, to: samples.count, by: 6) {
                collect(Double(samples[index]) / 32_768.0)
            }
        } else if !isFloat && bitsPerChannel == 8 {
            if isSignedInteger {
                let samples = rawBytes.bindMemory(to: Int8.self)
                for index in stride(from: 0, to: samples.count, by: 6) {
                    collect(Double(samples[index]) / 128.0)
                }
            } else {
                let samples = rawBytes.bindMemory(to: UInt8.self)
                for index in stride(from: 0, to: samples.count, by: 6) {
                    collect((Double(samples[index]) - 128.0) / 128.0)
                }
            }
        } else {
            // AVCaptureAudioDataOutput normally supplies Float32/Int16 PCM on iPhone. Refuse an
            // unfamiliar packing layout instead of interpreting (for example) packed 24-bit PCM
            // as Int16 and displaying a bogus level.
            return nil
        }

        guard sampleCount > 0 else { return nil }
        let rms = sqrt(squaredTotal / Double(sampleCount))
        // A little peak contribution makes consonants visible without turning a single click into
        // a full-scale meter. RMS remains the main measurement.
        let effectiveAmplitude = max(rms, peak * 0.28)
        let decibels = 20 * log10(max(effectiveAmplitude, 0.000_01))

        // Voice-friendly dB curve. Around -50 dBFS starts the first bar, normal speech usually
        // occupies the middle bars, and genuinely loud audio reaches the top bar.
        let gated = min(max((decibels + 54.0) / 44.0, 0), 1)
        return CGFloat(pow(gated, 0.72))
    }

    private func apply(_ normalized: CGFloat) {
        let now = ProcessInfo.processInfo.systemUptime

        lock.lock()
        defer { lock.unlock() }
        guard running else { return }

        let elapsed: Double
        if lastLevelUpdateTime > 0 {
            elapsed = min(max(now - lastLevelUpdateTime, 0), 0.25)
        } else {
            elapsed = 0.02
        }
        lastLevelUpdateTime = now

        if normalized >= level {
            // Fast attack so a spoken word is visible on the next ~90 ms HUD refresh.
            level = level * 0.18 + normalized * 0.82
        } else {
            // Time-based release instead of releasing once per audio buffer. The previous release
            // happened dozens of times between HUD refreshes, so speech peaks could disappear
            // before SwiftUI ever read them.
            let retention = CGFloat(pow(0.16, elapsed))
            level = max(normalized, level * retention + normalized * (1 - retention))
        }
    }
}
