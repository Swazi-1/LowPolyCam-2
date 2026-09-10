import AVFoundation
import Combine
import CoreMedia
import Foundation
import SwiftUI

struct AudioLevelMeterSnapshot: Equatable {
    var averagePowerDBFS: Double = -60
    var peakPowerDBFS: Double = -60
    var bars: Int = 0
    var isClipping: Bool = false
    var isAvailable: Bool = false

    static let unavailable = AudioLevelMeterSnapshot()

    init(averagePowerDBFS: Double = -60, peakPowerDBFS: Double = -60, bars: Int = 0,
         isClipping: Bool = false, isAvailable: Bool = false) {
        self.averagePowerDBFS = averagePowerDBFS
        self.peakPowerDBFS = peakPowerDBFS
        self.bars = bars
        self.isClipping = isClipping
        self.isAvailable = isAvailable
    }

    static func make(rms: Double, peak: Double, available: Bool = true) -> AudioLevelMeterSnapshot {
        let safeRMS = min(max(rms.isFinite ? rms : 0, 0), 1)
        let safePeak = min(max(peak.isFinite ? peak : 0, 0), 1)
        let averageDB = min(0, max(-60, 20 * log10(max(safeRMS, 0.001))))
        let peakDB = min(0, max(-60, 20 * log10(max(safePeak, 0.001))))
        let normalized = min(max((averageDB + 48) / 48, 0), 1)
        let bars = min(4, max(0, Int((normalized * 4).rounded(.up))))
        return AudioLevelMeterSnapshot(
            averagePowerDBFS: averageDB,
            peakPowerDBFS: peakDB,
            bars: bars,
            isClipping: peakDB >= -1.0,
            isAvailable: available
        )
    }
}

/// Reads the microphone's capture sample buffers directly. It intentionally does not create an
/// AVAudioRecorder, so recording and metering continue to share the session's authorized input.
final class AudioLevelMeter: NSObject, ObservableObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    let output = AVCaptureAudioDataOutput()
    let queue = DispatchQueue(label: "com.swazi.lowpolycam.audioMeter", qos: .utility)

    @Published private(set) var snapshot = AudioLevelMeterSnapshot.unavailable

    private let lock = NSLock()
    private var enabled = false
    private var generation = 0
    private var lastPublishUptime: TimeInterval = 0
    private var smoothedRMS = 0.001

    override init() {
        super.init()
        output.setSampleBufferDelegate(self, queue: queue)
    }

    func setEnabled(_ value: Bool) {
        lock.lock()
        enabled = value
        generation += 1
        smoothedRMS = 0.001
        lastPublishUptime = 0
        lock.unlock()
        if !value {
            DispatchQueue.main.async { [weak self] in
                self?.snapshot = .unavailable
            }
        }
    }

    func reset() {
        setEnabled(false)
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        lock.lock()
        guard enabled else { lock.unlock(); return }
        let currentGeneration = generation
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastPublishUptime >= 0.06 else { lock.unlock(); return }
        lastPublishUptime = now
        lock.unlock()

        guard let levels = Self.levels(from: sampleBuffer) else { return }
        let rms = levels.rms
        let peak = levels.peak

        lock.lock()
        guard enabled, generation == currentGeneration else { lock.unlock(); return }
        smoothedRMS = (smoothedRMS * 0.72) + (rms * 0.28)
        let smoothed = smoothedRMS
        lock.unlock()

        let next = AudioLevelMeterSnapshot.make(rms: smoothed, peak: peak)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let stillCurrent = self.enabled && self.generation == currentGeneration
            self.lock.unlock()
            if stillCurrent { self.snapshot = next }
        }
    }

    private static func levels(from sampleBuffer: CMSampleBuffer) -> (rms: Double, peak: Double)? {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(format),
              let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }

        var lengthAtOffset = 0
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: &lengthAtOffset,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        )
        guard status == kCMBlockBufferNoErr, let dataPointer, totalLength > 0 else { return nil }

        let asbd = streamDescription.pointee
        let bits = Int(asbd.mBitsPerChannel)
        let bytesPerSample = max(1, bits / 8)
        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isSignedInteger = (asbd.mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0
        guard asbd.mFormatID == kAudioFormatLinearPCM, isFloat || isSignedInteger else { return nil }

        let bytes = UnsafeRawBufferPointer(start: dataPointer, count: totalLength)
        let sampleCount = totalLength / bytesPerSample
        guard sampleCount > 0 else { return nil }

        var sumSquares = 0.0
        var peak = 0.0
        var counted = 0
        for index in 0..<sampleCount {
            let offset = index * bytesPerSample
            let value: Double
            if isFloat && bytesPerSample >= 4 {
                value = Double(bytes.load(fromByteOffset: offset, as: Float.self))
            } else if bytesPerSample >= 4 {
                value = Double(bytes.load(fromByteOffset: offset, as: Int32.self)) / Double(Int32.max)
            } else if bytesPerSample >= 2 {
                value = Double(bytes.load(fromByteOffset: offset, as: Int16.self)) / Double(Int16.max)
            } else if isSignedInteger {
                value = Double(Int8(bitPattern: bytes.load(fromByteOffset: offset, as: UInt8.self))) / Double(Int8.max)
            } else {
                value = (Double(bytes.load(fromByteOffset: offset, as: UInt8.self)) - 128) / 128
            }
            let normalized = min(max(abs(value.isFinite ? value : 0), 0), 1)
            sumSquares += normalized * normalized
            peak = max(peak, normalized)
            counted += 1
        }
        return counted > 0 ? (sqrt(sumSquares / Double(counted)), peak) : nil
    }
}

struct AudioLevelMeterView: View {
    @Environment(\.cameraTint) private var theme
    let snapshot: AudioLevelMeterSnapshot
    let mode: AudioLevelMeterMode

    var body: some View {
        Group {
            if !snapshot.isAvailable {
                EmptyView()
            } else {
                switch mode {
                case .off:
                    EmptyView()
                case .bars:
                    HStack(spacing: 2) {
                        ForEach(0..<4, id: \.self) { index in
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(color(for: index))
                                .frame(width: 3, height: CGFloat(4 + index * 2))
                        }
                    }
                    .frame(height: 20, alignment: .bottom)
                    .accessibilityLabel("Audio level")
                    .accessibilityValue(snapshot.isClipping ? "Clipping" : "\(snapshot.bars) of 4 bars")
                case .decibels:
                    Text(String(format: "%.0f dB", snapshot.averagePowerDBFS))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(snapshot.isClipping ? .red : .white)
                        .accessibilityLabel("Audio level")
                        .accessibilityValue(String(format: "%.0f dB", snapshot.averagePowerDBFS))
                }
            }
        }
    }

    private func color(for index: Int) -> Color {
        guard index < snapshot.bars else { return .white.opacity(0.22) }
        return snapshot.isClipping ? .red : theme
    }
}
