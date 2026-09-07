import Foundation

@main
enum RecordingRegressionTests {
    private static var checks = 0

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
        checks += 1
    }

    private static func gaps(_ times: [Double], fps: Double = 60) -> Int? {
        var counter = ClipFrameGapCounter(nominalFrameRate: fps)
        times.forEach { counter.append($0) }
        return counter.result()
    }

    static func main() throws {
        // Reference frames can precede adjacent B-frames in compressed sample delivery, including
        // at the old 512-sample boundary. None of these permutations lost an actual frame.
        var reordered: [Double] = [0]
        for start in stride(from: 1, to: 1_600, by: 3) {
            reordered.append(contentsOf: [start + 2, start, start + 1]
                .filter { $0 < 1_600 }.map { Double($0) / 60 })
        }
        expect(gaps(reordered) == 0, "Decode-order reordering must not count as dropped frames")
        let missing = reordered.filter { abs($0 - 512.0 / 60) > 0.000_001 }
        expect(gaps(missing) == 1, "A missing frame near a batch boundary must be counted once")
        expect(gaps(reordered, fps: 0) == 0, "Unknown nominal FPS should infer cadence")
        expect(gaps((0..<1_500).map { Double($0) / 240 }, fps: 240) == 0, "Clean HFR clip")
        expect(gaps([0, .nan, .infinity, 1.0 / 60, 2.0 / 60]) == 0, "Ignore invalid timestamps")
        expect(gaps([0, 1.0 / 60]) == nil, "Insufficient clips must report unavailable")

        var beyondWindow = (0..<1_500).map { Double($0) / 60 }
        let delayed = beyondWindow.remove(at: 1)
        beyondWindow.insert(delayed, at: 800)
        expect(gaps(beyondWindow) == nil, "Excessive reorder must report unavailable, not false gaps")

        var operation = RecordingOperationContext()
        operation.begin(splitSeconds: 60)
        operation.markStartIssued()
        operation.markStartConfirmed()
        expect(operation.segmentActive && !operation.startIssued, "Start callback clears pending-start ownership")
        operation.markSegmentBoundary()
        expect(operation.consumeSegmentContinuation(successful: true, sessionRunning: true), "Successful requested split continues")
        expect(!operation.segmentActive && !operation.startIssued, "Finished segment releases output ownership")
        operation.markStartIssued()
        expect(operation.cancelPendingStart(finalizeExistingSession: true), "Issued continuation awaits callback cleanup")
        expect(operation.discardOnFinish && operation.finalizationPending, "Canceled continuation stays finalizing")
        operation.finishDiscardedSegment(finalizeExistingSession: true)
        expect(operation.finalizationPending && !operation.startIssued && !operation.segmentActive,
               "Canceled continuation must still wait for earlier Photos imports")
        operation.reset()
        operation.begin(splitSeconds: 0)
        expect(!operation.cancelPendingStart(), "An unissued start needs no delegate cleanup")
        expect(!operation.requested && !operation.finalizationPending, "An unissued first start returns to idle")

        let gate = CaptureRequestGate()
        let oldZoom = gate.next(.zoom)
        let other = gate.next(.whiteBalance)
        expect(gate.isCurrent(oldZoom), "Unrelated requests preserve zoom token")
        let newZoom = gate.next(.zoom)
        expect(!gate.isCurrent(oldZoom) && gate.isCurrent(newZoom), "Newest zoom token wins")
        gate.invalidate(.whiteBalance)
        expect(!gate.isCurrent(other) && gate.isCurrent(newZoom), "Invalidation is scoped to its request kind")

        let fm = FileManager.default
        let name = "lowpolycam-regression-\(UUID().uuidString).mov"
        let source = fm.temporaryDirectory.appendingPathComponent(name)
        expect(CameraRecoveryStore.preserve(source) == nil, "A missing file cannot be reported as recovered")
        let payload = Data("recording regression".utf8)
        try payload.write(to: source)
        guard let retained = CameraRecoveryStore.preserve(source) else {
            preconditionFailure("Existing movie should be preserved")
        }
        defer { try? fm.removeItem(at: retained) }
        expect(!fm.fileExists(atPath: source.path), "Preservation moves source out of temporary storage")
        let recoveredPayload = try Data(contentsOf: retained)
        expect(recoveredPayload == payload, "Recovery retains movie bytes")
        expect(CameraRecoveryStore.preserve(retained) == retained, "Failed recovery retries keep the same file URL")
        expect(CameraRecoveryStore.recordings().contains(retained), "Preserved file appears in recovery inventory")

        print("Recording regressions passed (\(checks) checks)")
    }
}
