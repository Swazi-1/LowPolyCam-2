import Foundation

/// Counts presentation-time gaps without decoding video or retaining every timestamp in a clip.
/// Compressed samples arrive in decode order, so keep a lookahead across batch boundaries.
struct ClipFrameGapCounter {
    private static let batchSize = 512
    private static let lookaheadCount = batchSize / 2
    private var expectedCadence: Double
    private var timestamps: [Double] = []
    private var previousTime: Double?
    private var gapCount = 0
    private var validIntervals = 0
    private var invalidOrdering = false

    init(nominalFrameRate: Double) {
        expectedCadence = nominalFrameRate.isFinite && nominalFrameRate > 0 ? 1 / nominalFrameRate : 0
        timestamps.reserveCapacity(Self.batchSize)
    }

    mutating func append(_ timestamp: Double) {
        guard timestamp.isFinite, !invalidOrdering else { return }
        timestamps.append(timestamp)
        if timestamps.count >= Self.batchSize { consume(finishing: false) }
    }

    mutating func result() -> Int? {
        consume(finishing: true)
        guard !invalidOrdering, validIntervals > 1 else { return nil }
        return gapCount
    }

    private mutating func consume(finishing: Bool) {
        guard !timestamps.isEmpty, !invalidOrdering else { return }
        timestamps.sort()
        if expectedCadence <= 0, timestamps.count > 2 {
            let intervals = zip(timestamps.dropFirst(), timestamps)
                .map { $0.0 - $0.1 }
                .filter { $0 > 0 }
                .sorted()
            if !intervals.isEmpty { expectedCadence = intervals[intervals.count / 2] }
        }

        let count = finishing ? timestamps.count : timestamps.count - Self.lookaheadCount
        for time in timestamps.prefix(count) {
            if let previousTime {
                let interval = time - previousTime
                // An unusual stream can exceed the bounded reorder window. Report unavailable
                // rather than a convincing but incorrect dropped-frame count in that case.
                guard interval >= 0 else {
                    invalidOrdering = true
                    return
                }
                if interval > 0, expectedCadence > 0 {
                    validIntervals += 1
                    if interval > expectedCadence * 1.5 {
                        let missing = (interval / expectedCadence).rounded() - 1
                        guard missing.isFinite, missing < Double(Int.max - gapCount) else {
                            invalidOrdering = true
                            return
                        }
                        gapCount += max(0, Int(missing))
                    }
                }
            }
            previousTime = time
        }
        timestamps.removeFirst(count)
    }
}
