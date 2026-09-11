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
        let averageDB = min(0, max(AudioLevelMeterPolicy.minimumDBFS, 20 * log10(max(safeRMS, 0.001))))
        let peakDB = min(0, max(AudioLevelMeterPolicy.minimumDBFS, 20 * log10(max(safePeak, 0.001))))
        let bars = AudioLevelMeterPolicy.barCount(forAveragePowerDBFS: averageDB)
        return AudioLevelMeterSnapshot(
            averagePowerDBFS: averageDB,
            peakPowerDBFS: peakDB,
            bars: bars,
            isClipping: peakDB >= AudioLevelMeterPolicy.clippingDBFS,
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
        let bytesPerSample = max(1, Int((asbd.mBitsPerChannel + 7) / 8))
        let channels = max(1, Int(asbd.mChannelsPerFrame))
        let declaredBytesPerFrame = Int(asbd.mBytesPerFrame)
        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isSignedInteger = (asbd.mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0
        let isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        let isBigEndian = (asbd.mFormatFlags & kAudioFormatFlagIsBigEndian) != 0
        guard asbd.mFormatID == kAudioFormatLinearPCM else { return nil }

        let bytes = UnsafeRawBufferPointer(start: dataPointer, count: totalLength)
        let interleavedFrameStride = max(declaredBytesPerFrame, bytesPerSample * channels)
        let frameCount: Int
        let channelStride: Int
        if isNonInterleaved {
            frameCount = totalLength / max(bytesPerSample * channels, 1)
            channelStride = frameCount * bytesPerSample
        } else {
            frameCount = totalLength / interleavedFrameStride
            channelStride = 0
        }
        guard frameCount > 0 else { return nil }

        var sumSquares = 0.0
        var peak = 0.0
        var counted = 0
        for frame in 0..<frameCount {
            for channel in 0..<channels {
                let offset = isNonInterleaved
                    ? channel * channelStride + frame * bytesPerSample
                    : frame * interleavedFrameStride + channel * bytesPerSample
                guard offset >= 0, offset + bytesPerSample <= totalLength else { continue }

                let value: Double
                if isFloat && bytesPerSample >= 4 {
                    let raw = Self.readUnsigned(bytes, offset: offset, byteCount: 4, bigEndian: isBigEndian)
                    value = Double(Float(bitPattern: UInt32(raw)))
                } else if isSignedInteger {
                    let raw = Self.readUnsigned(bytes, offset: offset, byteCount: bytesPerSample, bigEndian: isBigEndian)
                    let signed = Self.signExtend(raw, bitCount: min(bits, 63))
                    let divisor = Double((Int64(1) << max(min(bits - 1, 62), 1)))
                    value = Double(signed) / divisor
                } else {
                    let raw = Self.readUnsigned(bytes, offset: offset, byteCount: bytesPerSample, bigEndian: isBigEndian)
                    let midpoint = Double(UInt64(1) << UInt64(max(bits - 1, 1)))
                    value = (Double(raw) - midpoint) / midpoint
                }
                let normalized = min(max(abs(value.isFinite ? value : 0), 0), 1)
                sumSquares += normalized * normalized
                peak = max(peak, normalized)
                counted += 1
            }
        }
        return counted > 0 ? (sqrt(sumSquares / Double(counted)), peak) : nil
    }

    private static func readUnsigned(
        _ bytes: UnsafeRawBufferPointer,
        offset: Int,
        byteCount: Int,
        bigEndian: Bool
    ) -> UInt64 {
        var value: UInt64 = 0
        if bigEndian {
            for index in 0..<byteCount {
                value = (value << 8) | UInt64(bytes[offset + index])
            }
        } else {
            for index in 0..<byteCount {
                value |= UInt64(bytes[offset + index]) << UInt64(index * 8)
            }
        }
        return value
    }

    private static func signExtend(_ raw: UInt64, bitCount: Int) -> Int64 {
        let bits = max(min(bitCount, 63), 1)
        let signBit = UInt64(1) << UInt64(bits - 1)
        guard raw & signBit != 0 else { return Int64(raw) }
        let mask = ~UInt64(0) << UInt64(bits)
        return Int64(bitPattern: raw | mask)
    }
}

struct AudioLevelMeterView: View {
    @AppStorage("iconAppearance") private var accentPreset = "Ice"
    @AppStorage("iconCustomRed") private var customRed = 0.55
    @AppStorage("iconCustomGreen") private var customGreen = 0.85
    @AppStorage("iconCustomBlue") private var customBlue = 1.0
    @AppStorage("audioPeakHold") private var audioPeakHold = true
    let snapshot: AudioLevelMeterSnapshot
    let mode: AudioLevelMeterMode
    @State private var peakHoldDBFS = AudioLevelMeterPolicy.minimumDBFS

    var body: some View {
        Group {
            if !snapshot.isAvailable {
                EmptyView()
            } else {
                switch mode {
                case .off:
                    EmptyView()
                case .bars:
                    HStack(alignment: .bottom, spacing: 2) {
                        ForEach(0..<AudioLevelMeterPolicy.defaultBarCount, id: \.self) { index in
                            let height = CGFloat(4 + index * 2)
                            ZStack(alignment: .top) {
                                RoundedRectangle(cornerRadius: 1.5)
                                    .fill(color(for: index))
                                if audioPeakHold && peakHoldBarCount == index + 1 {
                                    Capsule()
                                        .fill(levelColor)
                                        .frame(width: 5, height: 2)
                                        .offset(y: -4)
                                }
                            }
                            .frame(width: 3, height: height, alignment: .bottom)
                        }
                    }
                    .padding(.horizontal, usesBlackMeterColor ? 3 : 0)
                    .background(meterBackground, in: Capsule())
                    .frame(height: 20, alignment: .bottom)
                    .offset(y: -2)
                    .accessibilityLabel("Audio level")
                    .accessibilityValue(accessibilityBarsValue)
                case .decibels:
                    HStack(spacing: 4) {
                        Text(String(format: "%.0f dBFS", snapshot.averagePowerDBFS))
                        if audioPeakHold {
                            Text("pk \(String(format: "%.0f", peakHoldDBFS))")
                                .foregroundStyle(levelColor.opacity(0.68))
                        }
                    }
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(snapshot.isClipping ? .red : levelColor)
                    .padding(.horizontal, usesBlackMeterColor ? 3 : 0)
                    .background(meterBackground, in: Capsule())
                    .accessibilityLabel("Audio level in dBFS")
                    .accessibilityValue(accessibilityDecibelsValue)
                }
            }
        }
        .onAppear { updatePeakHold(for: snapshot) }
        .onChange(of: snapshot) { _, next in updatePeakHold(for: next) }
        .onChange(of: audioPeakHold) { _, enabled in
            if enabled {
                updatePeakHold(for: snapshot)
            } else {
                peakHoldDBFS = AudioLevelMeterPolicy.minimumDBFS
            }
        }
        .task(id: peakHoldDBFS) {
            guard audioPeakHold, snapshot.isAvailable, peakHoldDBFS > AudioLevelMeterPolicy.minimumDBFS else { return }
            do { try await Task.sleep(nanoseconds: 1_500_000_000) } catch { return }
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.12)) {
                peakHoldDBFS = max(AudioLevelMeterPolicy.minimumDBFS, peakHoldDBFS - 3)
            }
        }
    }

    private var levelColor: Color {
        // The meter is a level indicator, not another camera-control accent. Keep it white for
        // contrast, except when a user explicitly chooses pure white as the custom accent.
        usesBlackMeterColor ? .black : .white
    }

    private var usesBlackMeterColor: Bool {
        accentPreset == "Custom" &&
            customRed >= 0.98 && customGreen >= 0.98 && customBlue >= 0.98
    }

    private var meterBackground: Color {
        usesBlackMeterColor ? .white.opacity(0.88) : .clear
    }

    private func color(for index: Int) -> Color {
        guard index < snapshot.bars else { return levelColor.opacity(0.22) }
        return snapshot.isClipping ? .red : levelColor
    }

    private var peakHoldBarCount: Int {
        AudioLevelMeterPolicy.barCount(forAveragePowerDBFS: peakHoldDBFS)
    }

    private var accessibilityBarsValue: String {
        let current = snapshot.isClipping
            ? "Clipping"
            : "\(snapshot.bars) of \(AudioLevelMeterPolicy.defaultBarCount) bars"
        guard audioPeakHold, peakHoldDBFS > AudioLevelMeterPolicy.minimumDBFS else { return current }
        return "\(current), peak hold \(String(format: "%.0f dBFS", peakHoldDBFS))"
    }

    private var accessibilityDecibelsValue: String {
        let current = String(format: "%.0f dBFS", snapshot.averagePowerDBFS)
        guard audioPeakHold, peakHoldDBFS > AudioLevelMeterPolicy.minimumDBFS else { return current }
        return "\(current), peak hold \(String(format: "%.0f dBFS", peakHoldDBFS))"
    }

    private func updatePeakHold(for nextSnapshot: AudioLevelMeterSnapshot) {
        guard audioPeakHold, nextSnapshot.isAvailable else {
            if !nextSnapshot.isAvailable { peakHoldDBFS = AudioLevelMeterPolicy.minimumDBFS }
            return
        }
        let nextPeak = min(0, max(AudioLevelMeterPolicy.minimumDBFS, nextSnapshot.peakPowerDBFS))
        if nextPeak > peakHoldDBFS + 0.1 {
            peakHoldDBFS = nextPeak
        }
    }
}
