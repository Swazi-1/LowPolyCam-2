import AVFoundation
import AudioToolbox
import Foundation

/// Lightweight microphone level reader for the in-camera recording HUD.
/// It is independent from the movie writer, so it never changes the selected video codec.
final class AudioLevelMeter: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    let output = AVCaptureAudioDataOutput()
    private let queue = DispatchQueue(label: "com.swazi.lowpolycam.audioMeter", qos: .utility)
    private let lock = NSLock()
    private var running = false
    private var level: CGFloat = 0

    override init() {
        super.init()
        output.setSampleBufferDelegate(self, queue: queue)
    }

    func setRunning(_ value: Bool) {
        lock.lock()
        running = value
        level = 0
        lock.unlock()
    }

    func readLevel() -> CGFloat {
        lock.lock()
        defer { lock.unlock() }
        return level
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        lock.lock()
        let shouldMeasure = running
        lock.unlock()
        guard shouldMeasure,
              let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

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

        let streamDescription: UnsafePointer<AudioStreamBasicDescription>?
        if let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) {
            streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
        } else {
            streamDescription = nil
        }
        let bitsPerChannel = streamDescription?.pointee.mBitsPerChannel ?? 16
        let formatFlags = streamDescription?.pointee.mFormatFlags ?? 0
        let isFloat = bitsPerChannel == 32 && (formatFlags & kAudioFormatFlagIsFloat) != 0

        let rawBytes = UnsafeRawPointer(bytes)
        var squaredTotal = 0.0
        var sampleCount = 0

        if isFloat {
            let samples = rawBytes.assumingMemoryBound(to: Float32.self)
            let count = totalLength / MemoryLayout<Float32>.size
            for index in stride(from: 0, to: count, by: 8) {
                let value = Double(samples[index])
                squaredTotal += value * value
                sampleCount += 1
            }
        } else if bitsPerChannel == 32 {
            let samples = rawBytes.assumingMemoryBound(to: Int32.self)
            let count = totalLength / MemoryLayout<Int32>.size
            for index in stride(from: 0, to: count, by: 8) {
                let value = Double(samples[index]) / 2_147_483_648.0
                squaredTotal += value * value
                sampleCount += 1
            }
        } else {
            let samples = rawBytes.assumingMemoryBound(to: Int16.self)
            let count = totalLength / MemoryLayout<Int16>.size
            for index in stride(from: 0, to: count, by: 8) {
                let value = Double(samples[index]) / 32_768.0
                squaredTotal += value * value
                sampleCount += 1
            }
        }

        guard sampleCount > 0 else { return }
        let rms = sqrt(squaredTotal / Double(sampleCount))
        let decibels = 20 * log10(max(rms, 0.000_01))
        let normalized = CGFloat(min(max((decibels + 55) / 55, 0), 1))

        lock.lock()
        if running {
            level = level * 0.72 + normalized * 0.28
        }
        lock.unlock()
    }
}
