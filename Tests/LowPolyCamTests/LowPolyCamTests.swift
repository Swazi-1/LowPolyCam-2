import Foundation
import XCTest
@testable import LowPolyCam

final class LowPolyCamTests: XCTestCase {
    func testRequestTokenRejectsStaleRequests() {
        let token = RequestToken("test")
        let first = token.next()
        let second = token.next()

        XCTAssertFalse(token.isLatest(first))
        XCTAssertTrue(token.isLatest(second))
        XCTAssertEqual(token.current(), second)
    }

    func testVideoQualityValuesRemainStable() {
        XCTAssertEqual(VideoResolution.p4k.dimensions.width, 3_840)
        XCTAssertEqual(VideoResolution.p4k.dimensions.height, 2_160)
        XCTAssertEqual(VideoFrameRate.allCases.map(\.rawValue), [24, 30, 60])
        XCTAssertEqual(CameraManager.SlowMotionFrameRate.allCases.map(\.rawValue), [120, 240])
    }

    func testStorageReserveNeverDropsBelowSafetyFloor() {
        let reserve = StorageGuard.criticalReserveBytes(forVideoBitrate: 2_000_000)
        XCTAssertGreaterThanOrEqual(reserve, StorageGuard.minimumCriticalReserveBytes)
        XCTAssertGreaterThan(StorageGuard.criticalReserveBytes(forVideoBitrate: 80_000_000), reserve)
    }

    func testRecordingClockUsesMonotonicProviderAndResets() {
        var uptime = 100.0
        let clock = RecordingClockState(uptimeProvider: { uptime })

        clock.startIfNeeded()
        uptime = 103.9
        clock.update()
        XCTAssertEqual(clock.elapsedSeconds, 3)

        clock.stopAndReset()
        XCTAssertEqual(clock.elapsedSeconds, 0)
    }

    func testPreferenceMigrationNormalizesInvalidValues() {
        let suiteName = "LowPolyCamTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set("invalid", forKey: LowPolyCamPreferences.Key.selectedVideoResolution)
        defaults.set(999, forKey: LowPolyCamPreferences.Key.selectedVideoFrameRate)
        defaults.set(4.5, forKey: LowPolyCamPreferences.Key.gridOpacity)

        LowPolyCamPreferences.registerAndMigrate(defaults)

        XCTAssertEqual(defaults.string(forKey: LowPolyCamPreferences.Key.selectedVideoResolution), "1080p")
        XCTAssertEqual(defaults.integer(forKey: LowPolyCamPreferences.Key.selectedVideoFrameRate), 60)
        XCTAssertEqual(defaults.double(forKey: LowPolyCamPreferences.Key.gridOpacity), 1.0, accuracy: 0.0001)
        XCTAssertEqual(defaults.integer(forKey: LowPolyCamPreferences.Key.schemaVersion), LowPolyCamPreferences.currentSchemaVersion)
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testInvalidMediaIsRejected() {
        let result = MediaValidator.validatePhoto(
            data: Data("not an image".utf8),
            expectedAspect: "4:3",
            requestedMegapixels: 12
        )
        XCTAssertFalse(result.isValid)
        XCTAssertFalse(MediaValidator.validatePhotoFile(at: URL(fileURLWithPath: "/missing/photo.jpg")).isValid)
    }

    func testRecoveryDeleteRejectsFilesOutsideRecoveryDirectory() {
        XCTAssertFalse(CameraRecoveryStore.delete(URL(fileURLWithPath: "/tmp/lowpolycam-not-recovery.mov")))
    }

    func testRecordingSessionManifestRoundTrips() throws {
        let segment = RecordingSessionSegment(
            sessionID: "session",
            segmentIndex: 1,
            filename: "img_0001.mov",
            mode: "VIDEO",
            cameraPosition: "back",
            resolution: "4K",
            frameRate: 60,
            codec: "HEVC",
            compression: "High",
            duration: 12.5,
            recordedAt: Date(timeIntervalSince1970: 123)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(
            RecordingSessionSegment.self,
            from: encoder.encode(segment)
        )

        XCTAssertEqual(decoded.sessionID, segment.sessionID)
        XCTAssertEqual(decoded.segmentIndex, segment.segmentIndex)
        XCTAssertEqual(decoded.frameRate, segment.frameRate)
        XCTAssertEqual(decoded.duration, segment.duration, accuracy: 0.001)
    }
}
