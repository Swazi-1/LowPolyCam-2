import Foundation

@main
enum StateRegressionTests {
    private static var checks = 0

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
        checks += 1
    }

    static func main() throws {
        // A failed full capture request must choose rollback; a committed request must not.
        var failedTransaction = CaptureConfigurationTransaction()
        failedTransaction.begin()
        expect(failedTransaction.state == .applying, "Transaction enters applying state")
        expect(failedTransaction.finish(success: false), "Failed configuration requests rollback")
        expect(failedTransaction.state == .rollingBack, "Failed transaction enters rollback state")
        failedTransaction.didRollback()
        expect(failedTransaction.state == .rolledBack, "Rollback completion is recorded")

        var successfulTransaction = CaptureConfigurationTransaction()
        successfulTransaction.begin()
        expect(!successfulTransaction.finish(success: true), "Successful configuration does not roll back")
        expect(successfulTransaction.state == .committed, "Successful configuration commits")

        // Longevity backups are camera-specific and enabling the derived override never mutates them.
        let back = LongevityModeState.NormalVideoSelection(
            resolution: "4K",
            frameRate: 60,
            codec: "HEVC",
            compression: "High"
        )
        let front = LongevityModeState.NormalVideoSelection(
            resolution: "1080p",
            frameRate: 30,
            codec: "H264",
            compression: "Medium"
        )
        var longevity = LongevityModeState()
        longevity.rememberNormalSelection(back, for: .back)
        longevity.rememberNormalSelection(front, for: .front)
        longevity.commitEnabled(true)
        expect(longevity.enabled, "Longevity state enables only after commit")
        expect(longevity.normalSelection(for: .back) == back, "Back-camera normal selection is preserved")
        expect(longevity.normalSelection(for: .front) == front, "Front-camera normal selection is preserved")
        longevity.commitEnabled(false)
        expect(longevity.normalSelection(for: .back) == back, "Disabling Longevity keeps back backup intact")
        expect(longevity.normalSelection(for: .front) == front, "Disabling Longevity keeps front backup intact")

        // Full-resolution photo processing has hard backpressure rather than an unbounded queue.
        var photoGate = BoundedInFlightGate(capacity: 2)
        expect(photoGate.reserve(), "First photo processing slot is accepted")
        expect(photoGate.reserve(), "Second photo processing slot is accepted")
        expect(!photoGate.reserve(), "Photo processing rejects work past capacity")
        expect(photoGate.inFlight == 2, "Rejected work does not grow the queue")
        photoGate.release()
        expect(photoGate.reserve(), "A completed photo frees capacity")
        photoGate.release()
        photoGate.release()
        photoGate.release()
        expect(photoGate.inFlight == 0, "Extra releases cannot underflow the in-flight count")

        // Recovery retry state accepts each durable item once until its Photos callback finishes.
        let retryA = URL(fileURLWithPath: "/tmp/recovery-a.mov")
        let retryB = URL(fileURLWithPath: "/tmp/recovery-b.jpg")
        var retryState = RecoveryRetryState()
        expect(retryState.begin([retryA, retryB, retryA]) == [retryA, retryB],
               "Recovery retry starts each item only once")
        expect(retryState.contains(retryA) && retryState.contains(retryB),
               "Started recovery items are marked in flight")
        expect(retryState.begin([retryA]).isEmpty,
               "Repeated Retry taps do not enqueue an in-flight item twice")
        retryState.finish(retryA)
        expect(!retryState.contains(retryA) && retryState.contains(retryB),
               "Finishing one retry preserves the other in-flight item")
        expect(retryState.begin([retryA]) == [retryA],
               "A completed recovery item may be retried again if it still exists")
        retryState.finish(retryA)
        retryState.finish(retryB)

        // Recovery state supports both photos and recordings, and launch reconciliation preserves
        // a durable pending movie instead of leaving it undiscoverable.
        let fm = FileManager.default
        let token = UUID().uuidString
        let photoName = "state-regression-\(token).jpg"
        let movieName = "state-regression-\(token).mov"
        let photoPayload = Data("photo recovery regression".utf8)
        let moviePayload = Data("movie recovery regression".utf8)

        guard let stagedPhoto = CameraRecoveryStore.stagePhoto(photoPayload, filename: photoName) else {
            preconditionFailure("Photo staging should succeed")
        }
        defer { CameraRecoveryStore.remove(stagedPhoto) }
        expect(CameraRecoveryStore.items().contains { $0.url == stagedPhoto && $0.kind == .photo },
               "Staged photo appears in recovery inventory")
        let stagedPhotoPayload = try Data(contentsOf: stagedPhoto)
        expect(stagedPhotoPayload == photoPayload, "Staged photo bytes are durable")

        guard let pendingMovie = CameraRecoveryStore.prepareRecordingDestination(filename: movieName) else {
            preconditionFailure("Pending recording destination should be created")
        }
        try moviePayload.write(to: pendingMovie)
        expect(CameraRecoveryStore.containsFilename(movieName), "Pending recording filename is reserved")
        let reconciled = CameraRecoveryStore.reconcilePendingRecordings()
        guard let recoveredMovie = reconciled.first(where: { $0.lastPathComponent.hasPrefix("state-regression-\(token)") }) else {
            preconditionFailure("Pending movie should reconcile into recovery")
        }
        defer { CameraRecoveryStore.remove(recoveredMovie) }
        expect(!fm.fileExists(atPath: pendingMovie.path), "Reconciliation moves pending movie out of in-progress storage")
        expect(CameraRecoveryStore.items().contains { $0.url == recoveredMovie && $0.kind == .recording },
               "Reconciled movie appears as a recording")
        let recoveredMoviePayload = try Data(contentsOf: recoveredMovie)
        expect(recoveredMoviePayload == moviePayload, "Reconciled movie retains its bytes")
        expect(CameraRecoveryStore.preserve(recoveredMovie) == recoveredMovie,
               "Retrying an already-recovered item keeps one stable URL")

        print("State regressions passed (\(checks) checks)")
    }
}
