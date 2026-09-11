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

    func testUnsupported4K60H264AlwaysNormalizesToHEVC() {
        XCTAssertEqual(
            CameraManager.normalizedVideoCodec("H264", resolution: .p4k, frameRate: .fps60),
            "HEVC"
        )
        XCTAssertEqual(
            CameraManager.normalizedVideoCodec("H264", resolution: .p1080, frameRate: .fps60),
            "H264"
        )
        XCTAssertEqual(
            CameraManager.normalizedVideoCodec("HEVC", resolution: .p4k, frameRate: .fps60),
            "HEVC"
        )
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

    func testRecordingClockExcludesPausedWallTime() {
        var uptime = 100.0
        let clock = RecordingClockState(uptimeProvider: { uptime })

        clock.startIfNeeded()
        uptime = 103.9
        clock.update()
        XCTAssertEqual(clock.elapsedSeconds, 3)

        clock.pause()
        uptime = 120.0
        clock.update()
        XCTAssertEqual(clock.elapsedSeconds, 3)

        clock.resume()
        uptime = 121.2
        clock.update()
        XCTAssertEqual(clock.elapsedSeconds, 5)
        clock.stopAndReset()
    }

    func testPreferenceMigrationNormalizesInvalidValues() {
        let suiteName = "LowPolyCamTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set("invalid", forKey: LowPolyCamPreferences.Key.selectedVideoResolution)
        defaults.set(999, forKey: LowPolyCamPreferences.Key.selectedVideoFrameRate)
        defaults.set(4.5, forKey: LowPolyCamPreferences.Key.gridOpacity)
        defaults.set("invalid", forKey: LowPolyCamPreferences.Key.gridStyle)
        defaults.set("invalid", forKey: LowPolyCamPreferences.Key.audioLevelMeter)
        defaults.set("invalid", forKey: LowPolyCamPreferences.Key.cleanPreviewGesture)
        defaults.set("invalid", forKey: LowPolyCamPreferences.Key.captureOrientation)
        defaults.set(2, forKey: LowPolyCamPreferences.Key.recordingStartCountdown)
        defaults.set(999, forKey: LowPolyCamPreferences.Key.videoManualBitrateMbps)
        defaults.set(-1, forKey: LowPolyCamPreferences.Key.customWhiteBalanceTemperature)
        defaults.set(999, forKey: LowPolyCamPreferences.Key.customWhiteBalanceTint)
        defaults.set("Whatever", forKey: LowPolyCamPreferences.Key.focusExposureLockMode)
        defaults.set(2, forKey: LowPolyCamPreferences.Key.tapFocusResetSeconds)

        LowPolyCamPreferences.registerAndMigrate(defaults)

        XCTAssertEqual(defaults.string(forKey: LowPolyCamPreferences.Key.selectedVideoResolution), "1080p")
        XCTAssertEqual(defaults.integer(forKey: LowPolyCamPreferences.Key.selectedVideoFrameRate), 60)
        XCTAssertEqual(defaults.double(forKey: LowPolyCamPreferences.Key.gridOpacity), 1.0, accuracy: 0.0001)
        XCTAssertEqual(defaults.string(forKey: LowPolyCamPreferences.Key.gridStyle), GridStyle.ruleOfThirds.rawValue)
        XCTAssertEqual(defaults.string(forKey: LowPolyCamPreferences.Key.audioLevelMeter), AudioLevelMeterMode.bars.rawValue)
        XCTAssertEqual(defaults.string(forKey: LowPolyCamPreferences.Key.cleanPreviewGesture), CleanPreviewGesture.doubleTap.rawValue)
        XCTAssertEqual(defaults.string(forKey: LowPolyCamPreferences.Key.captureOrientation), CaptureOrientationPreference.auto.rawValue)
        XCTAssertEqual(defaults.integer(forKey: LowPolyCamPreferences.Key.recordingStartCountdown), 0)
        XCTAssertEqual(defaults.double(forKey: LowPolyCamPreferences.Key.videoManualBitrateMbps), ManualBitratePolicy.maximumMbps, accuracy: 0.0001)
        XCTAssertEqual(defaults.double(forKey: LowPolyCamPreferences.Key.customWhiteBalanceTemperature), WhiteBalancePreferencePolicy.minimumTemperature, accuracy: 0.0001)
        XCTAssertEqual(defaults.double(forKey: LowPolyCamPreferences.Key.customWhiteBalanceTint), WhiteBalancePreferencePolicy.maximumTint, accuracy: 0.0001)
        XCTAssertEqual(defaults.string(forKey: LowPolyCamPreferences.Key.focusExposureLockMode), "AE/AF")
        XCTAssertEqual(defaults.integer(forKey: LowPolyCamPreferences.Key.tapFocusResetSeconds), 1)
        XCTAssertTrue(defaults.bool(forKey: LowPolyCamPreferences.Key.photoCaptureFlash))
        XCTAssertFalse(defaults.bool(forKey: LowPolyCamPreferences.Key.frontScreenFlash))
        XCTAssertFalse(defaults.bool(forKey: LowPolyCamPreferences.Key.frameGuidesEnabled))
        XCTAssertTrue(defaults.bool(forKey: LowPolyCamPreferences.Key.audioPeakHold))
        XCTAssertFalse(defaults.bool(forKey: LowPolyCamPreferences.Key.cameraHUDLens))
        XCTAssertEqual(defaults.integer(forKey: LowPolyCamPreferences.Key.schemaVersion), LowPolyCamPreferences.currentSchemaVersion)
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testFreshInstallDefaultsMatchShippingCameraSetup() {
        let suiteName = "LowPolyCamFreshDefaults-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        LowPolyCamPreferences.registerAndMigrate(defaults)

        XCTAssertEqual(defaults.string(forKey: LowPolyCamPreferences.Key.appColorScheme), "dark")
        XCTAssertEqual(defaults.string(forKey: LowPolyCamPreferences.Key.iconAppearance), "Ice")
        XCTAssertEqual(defaults.string(forKey: LowPolyCamPreferences.Key.selectedVideoResolution), "1080p")
        XCTAssertEqual(defaults.integer(forKey: LowPolyCamPreferences.Key.selectedVideoFrameRate), 60)
        XCTAssertEqual(defaults.string(forKey: LowPolyCamPreferences.Key.selectedVideoCodec), "HEVC")
        XCTAssertEqual(defaults.string(forKey: LowPolyCamPreferences.Key.videoCompressionMode), "Auto")
        XCTAssertEqual(defaults.string(forKey: LowPolyCamPreferences.Key.videoCompression), "High")
        XCTAssertTrue(defaults.bool(forKey: LowPolyCamPreferences.Key.videoStabilizationEnabled))
        XCTAssertEqual(defaults.string(forKey: LowPolyCamPreferences.Key.selectedSlowMotionResolution), "1080p")
        XCTAssertEqual(defaults.integer(forKey: LowPolyCamPreferences.Key.selectedSlowMotionFrameRate), 240)
        XCTAssertEqual(defaults.string(forKey: LowPolyCamPreferences.Key.slowMotionCompressionMode), "Auto")
        XCTAssertEqual(defaults.string(forKey: LowPolyCamPreferences.Key.slowMotionCompressionLevel), "High")
        XCTAssertEqual(defaults.integer(forKey: LowPolyCamPreferences.Key.selectedPhotoMegapixels), 12)
        XCTAssertEqual(defaults.string(forKey: LowPolyCamPreferences.Key.photoFileFormat), "HEIC")
        XCTAssertEqual(defaults.string(forKey: LowPolyCamPreferences.Key.photoAspect), "4:3")
        XCTAssertEqual(defaults.string(forKey: LowPolyCamPreferences.Key.cleanPreviewGesture), CleanPreviewGesture.doubleTap.rawValue)
        XCTAssertEqual(defaults.double(forKey: LowPolyCamPreferences.Key.torchBrightness), 0.40, accuracy: 0.0001)
        XCTAssertTrue(defaults.bool(forKey: LowPolyCamPreferences.Key.cameraHUDEnabled))
        XCTAssertTrue(defaults.bool(forKey: LowPolyCamPreferences.Key.cameraHUDResolution))
        XCTAssertTrue(defaults.bool(forKey: LowPolyCamPreferences.Key.cameraHUDFPS))
        XCTAssertTrue(defaults.bool(forKey: LowPolyCamPreferences.Key.cameraHUDBattery))
        XCTAssertFalse(defaults.bool(forKey: LowPolyCamPreferences.Key.cameraHUDRemaining))
        XCTAssertFalse(defaults.bool(forKey: LowPolyCamPreferences.Key.cameraHUDWhiteBalance))
        XCTAssertFalse(defaults.bool(forKey: LowPolyCamPreferences.Key.cameraHUDLens))
        XCTAssertFalse(defaults.bool(forKey: LowPolyCamPreferences.Key.cameraHUDStorage))
        XCTAssertFalse(defaults.bool(forKey: LowPolyCamPreferences.Key.cameraHUDDroppedFrames))
        XCTAssertFalse(defaults.bool(forKey: LowPolyCamPreferences.Key.thermalHUD))

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

    func testManualBitratePolicyClampsInvalidValues() {
        XCTAssertEqual(ManualBitratePolicy.validatedMbps(.nan), ManualBitratePolicy.defaultMbps)
        XCTAssertEqual(ManualBitratePolicy.validatedMbps(.infinity), ManualBitratePolicy.defaultMbps)
        XCTAssertEqual(ManualBitratePolicy.validatedMbps(.nan, fallback: .infinity), ManualBitratePolicy.defaultMbps)
        XCTAssertEqual(ManualBitratePolicy.validatedMbps(1), 1)
        XCTAssertEqual(ManualBitratePolicy.validatedMbps(50), 50)
        XCTAssertEqual(ManualBitratePolicy.validatedMbps(200), 200)
        XCTAssertEqual(ManualBitratePolicy.validatedMbps(0), ManualBitratePolicy.minimumMbps)
        XCTAssertEqual(ManualBitratePolicy.validatedMbps(-10), ManualBitratePolicy.minimumMbps)
        XCTAssertEqual(ManualBitratePolicy.validatedMbps(999), ManualBitratePolicy.maximumMbps)
        XCTAssertEqual(ManualBitratePolicy.bitsPerSecond(forMbps: 12.5), 12_500_000)
    }

    func testManualBitratePolicyUsesFormatAwareEffectiveRangesWithoutMutatingRequest() {
        let expectedMaximums: [(resolution: VideoResolution, fps: Double, isSlowMotion: Bool, maximum: Double)] = [
            (.p720, 24, false, 12), (.p720, 30, false, 12), (.p720, 60, false, 18),
            (.p1080, 24, false, 24), (.p1080, 30, false, 24), (.p1080, 60, false, 40),
            (.p4k, 24, false, 80), (.p4k, 30, false, 80), (.p4k, 60, false, 140),
            (.p720, 120, true, 40), (.p720, 240, true, 60),
            (.p1080, 120, true, 90), (.p1080, 240, true, 140)
        ]
        for expected in expectedMaximums {
            XCTAssertEqual(
                ManualBitratePolicy.recommendation(
                    resolution: expected.resolution,
                    fps: expected.fps,
                    isSlowMotion: expected.isSlowMotion,
                    codec: "HEVC"
                ).maximumMbps,
                expected.maximum
            )
        }

        let video720p60 = ManualBitratePolicy.recommendation(
            resolution: .p720,
            fps: 60,
            isSlowMotion: false,
            codec: "HEVC"
        )
        XCTAssertEqual(video720p60.recommendedMbps, 10)
        XCTAssertEqual(video720p60.maximumMbps, 18)
        XCTAssertEqual(
            ManualBitratePolicy.effectiveMbps(
                requested: 100,
                resolution: .p720,
                fps: 60,
                isSlowMotion: false,
                codec: "HEVC"
            ),
            18
        )

        let video4K60 = ManualBitratePolicy.recommendation(
            resolution: .p4k,
            fps: 60,
            isSlowMotion: false,
            codec: "HEVC"
        )
        XCTAssertEqual(video4K60.maximumMbps, 140)
        XCTAssertEqual(
            ManualBitratePolicy.effectiveMbps(
                requested: 100,
                resolution: .p4k,
                fps: 60,
                isSlowMotion: false,
                codec: "HEVC"
            ),
            100
        )

        let sloMo1080p240 = ManualBitratePolicy.recommendation(
            resolution: .p1080,
            fps: 240,
            isSlowMotion: true,
            codec: "HEVC"
        )
        XCTAssertEqual(sloMo1080p240.recommendedMbps, 70)
        XCTAssertEqual(sloMo1080p240.maximumMbps, 140)
        XCTAssertEqual(ManualBitratePolicy.validatedMbps(100), 100)
    }

    func testWhiteBalanceAndZoomPoliciesClampAndDeduplicate() {
        XCTAssertEqual(WhiteBalancePreferencePolicy.validatedTemperature(.nan), 5_200)
        XCTAssertEqual(WhiteBalancePreferencePolicy.validatedTemperature(2_000), 2_500)
        XCTAssertEqual(WhiteBalancePreferencePolicy.validatedTemperature(20_000), 10_000)
        XCTAssertEqual(WhiteBalancePreferencePolicy.validatedTint(-999), -150)
        XCTAssertEqual(WhiteBalancePreferencePolicy.validatedTint(999), 150)

        XCTAssertEqual(
            ZoomShortcutPolicy.validated([0.5, 0.501, 2, .infinity, 999]),
            [0.5, 2, 100]
        )
    }

    func testTorchLevelPolicyStaysInNormalizedDomain() {
        XCTAssertEqual(TorchLevelPolicy.validatedNormalized(0.35), 0.35, accuracy: 0.0001)
        XCTAssertEqual(TorchLevelPolicy.validatedNormalized(-1), 0.05, accuracy: 0.0001)
        XCTAssertEqual(TorchLevelPolicy.validatedNormalized(.infinity), 0.40, accuracy: 0.0001)
        XCTAssertEqual(
            TorchLevelPolicy.validatedNormalized(3.402823466e38),
            1.0,
            accuracy: 0.0001
        )
    }

    func testCustomWhiteBalanceQueueKeepsOnlyLatestSubmission() {
        var queue = CustomWhiteBalanceSubmissionQueue()
        queue.submit(CustomWhiteBalanceSubmission(temperature: 3_200, tint: -10, isFinal: false))
        queue.submit(CustomWhiteBalanceSubmission(temperature: 6_500, tint: 12, isFinal: true))

        XCTAssertEqual(
            queue.consumeLatest(),
            CustomWhiteBalanceSubmission(temperature: 6_500, tint: 12, isFinal: true)
        )
        XCTAssertNil(queue.consumeLatest())
    }

    func testAudioBarsAreMonotonicAndClamped() {
        let values = [-60.0, -48.0, -24.0, -12.0, 0.0]
        let bars = values.map { AudioLevelMeterPolicy.barCount(forAveragePowerDBFS: $0) }

        XCTAssertEqual(bars, bars.sorted())
        XCTAssertEqual(bars.first, 0)
        XCTAssertEqual(bars.last, AudioLevelMeterPolicy.defaultBarCount)
        XCTAssertEqual(AudioLevelMeterPolicy.barCount(forAveragePowerDBFS: .nan), 0)
    }

    func testShutterRowKeepsTheCenterSlotStable() {
        for width in [320.0, 390.0, 844.0] {
            XCTAssertEqual(
                ShutterRowLayoutPolicy.shutterCenterX(in: CGFloat(width)),
                CGFloat(width / 2),
                accuracy: 0.0001
            )
        }
        XCTAssertEqual(ShutterRowLayoutPolicy.sideSlotWidth, 48)
        XCTAssertEqual(ShutterRowLayoutPolicy.shutterSlotWidth, 76)
    }

    func testZoomButtonsDefaultOffWithoutResettingConfiguredValues() {
        let suiteName = "LowPolyCamZoomTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(5, forKey: LowPolyCamPreferences.Key.zoomButtonCount)
        defaults.set(8.0, forKey: LowPolyCamPreferences.Key.zoomButton1)
        defaults.set(12.0, forKey: LowPolyCamPreferences.Key.zoomButton2)

        LowPolyCamPreferences.registerAndMigrate(defaults)

        XCTAssertFalse(defaults.bool(forKey: LowPolyCamPreferences.Key.zoomButtonsEnabled))
        XCTAssertEqual(defaults.integer(forKey: LowPolyCamPreferences.Key.zoomButtonCount), 5)
        XCTAssertEqual(defaults.double(forKey: LowPolyCamPreferences.Key.zoomButton1), 8.0, accuracy: 0.0001)
        XCTAssertEqual(defaults.double(forKey: LowPolyCamPreferences.Key.zoomButton2), 12.0, accuracy: 0.0001)
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testSettingsSearchRoutesFollowTheFlattenedHierarchy() {
        let entries = VideoSettingsView.searchEntries
        XCTAssertEqual(
            entries.first(where: { $0.title == "Custom Zoom Buttons" })?.destination,
            .zoomControls
        )
        XCTAssertEqual(
            entries.first(where: { $0.title == "Clean Preview Gesture" })?.destination,
            .quickControls
        )
        XCTAssertEqual(
            entries.first(where: { $0.title == "Audio Level Meter" })?.destination,
            .cameraHUD
        )
        XCTAssertEqual(
            entries.first(where: { $0.title == "Custom White Balance" })?.destination,
            .preferences
        )
        let removedHUDRoute = ["HUD", "Content", "&", "Style"].joined(separator: " ")
        XCTAssertFalse(entries.contains { $0.path.contains(removedHUDRoute) })
    }

    func testRecordingPauseMachineRejectsInvalidTransitions() {
        var machine = RecordingPauseMachine()
        XCTAssertFalse(machine.requestPause())
        XCTAssertTrue(machine.start())
        XCTAssertFalse(machine.start())
        XCTAssertTrue(machine.requestPause())
        XCTAssertFalse(machine.requestPause())
        XCTAssertFalse(machine.requestResume())
        XCTAssertTrue(machine.confirmPaused())
        XCTAssertFalse(machine.confirmPaused())
        XCTAssertTrue(machine.requestResume())
        XCTAssertFalse(machine.requestResume())
        XCTAssertFalse(machine.requestPause())
        XCTAssertTrue(machine.confirmResumed())
        XCTAssertFalse(machine.requestResume())
        XCTAssertTrue(machine.requestStop())
        XCTAssertFalse(machine.requestStop())
        XCTAssertTrue(machine.completeStop())
        XCTAssertFalse(machine.completeStop())
    }

    func testRecordingPauseMachineStopsWhilePaused() {
        var machine = RecordingPauseMachine()
        XCTAssertTrue(machine.start())
        XCTAssertTrue(machine.requestPause())
        XCTAssertTrue(machine.confirmPaused())
        XCTAssertTrue(machine.requestStop())
        XCTAssertEqual(machine.state, .stopping)
        XCTAssertTrue(machine.completeStop())
        XCTAssertEqual(machine.state, .idle)
    }

    func testRecordingPauseMachineLifecycleCleanupFromPausedState() {
        var machine = RecordingPauseMachine()
        XCTAssertTrue(machine.start())
        XCTAssertTrue(machine.requestPause())
        XCTAssertTrue(machine.confirmPaused())
        XCTAssertTrue(machine.requestStop())
        XCTAssertTrue(machine.completeStop())
        machine.reset()
        XCTAssertEqual(machine.state, .idle)
    }

    func testRecordingSplitTimingWaitsUntilRecordingIsActive() {
        XCTAssertEqual(
            RecordingSplitTimingPolicy.remainingDuration(splitDuration: 30, recordedDuration: 10),
            20
        )
        XCTAssertFalse(
            RecordingSplitTimingPolicy.shouldSplit(
                splitDuration: 30,
                recordedDuration: 30,
                pauseState: .paused
            )
        )
        XCTAssertTrue(
            RecordingSplitTimingPolicy.shouldSplit(
                splitDuration: 30,
                recordedDuration: 30,
                pauseState: .recording
            )
        )
    }

    func testRecordingCountdownMachineTicksAndCancels() {
        var machine = RecordingCountdownMachine()
        XCTAssertFalse(machine.start(seconds: 2))
        XCTAssertTrue(machine.start(seconds: 3))
        XCTAssertEqual(machine.state, .countingDown(remaining: 3))
        XCTAssertTrue(machine.tick())
        XCTAssertEqual(machine.state, .countingDown(remaining: 2))
        XCTAssertTrue(machine.tick())
        XCTAssertTrue(machine.tick())
        XCTAssertEqual(machine.state, .idle)
        XCTAssertFalse(machine.cancel())
    }

    func testCameraPresetMigrationAndPersistence() throws {
        let invalid = CameraPreset(
            name: "  ",
            captureMode: "invalid",
            videoResolution: "invalid",
            videoFrameRate: 999,
            slowMotionResolution: "invalid",
            slowMotionFrameRate: 999,
            codec: "invalid",
            videoCompressionMode: "invalid",
            videoCompressionLevel: "invalid",
            videoManualBitrateMbps: .infinity,
            slowMotionCompressionMode: "invalid",
            slowMotionCompressionLevel: "invalid",
            slowMotionManualBitrateMbps: .nan,
            zoom: .nan,
            stabilization: true,
            whiteBalance: "invalid",
            customWhiteBalanceTemperature: 50,
            customWhiteBalanceTint: -999,
            cameraPosition: "invalid"
        )
        let migrated = invalid.migrated()
        XCTAssertEqual(migrated.name, "Custom Preset")
        XCTAssertEqual(migrated.captureMode, "VIDEO")
        XCTAssertEqual(migrated.videoResolution, "1080p")
        XCTAssertEqual(migrated.videoFrameRate, 60)
        XCTAssertEqual(migrated.videoManualBitrateMbps, ManualBitratePolicy.defaultMbps)
        XCTAssertEqual(migrated.slowMotionManualBitrateMbps, ManualBitratePolicy.defaultMbps)
        XCTAssertEqual(migrated.customWhiteBalanceTemperature, 2_500)
        XCTAssertEqual(migrated.customWhiteBalanceTint, -150)
        XCTAssertEqual(migrated.cameraPosition, "back")

        let suiteName = "LowPolyCamPresetTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        CameraPresetStore.save([migrated], to: defaults)
        let loaded = CameraPresetStore.load(from: defaults)
        XCTAssertEqual(loaded, [migrated])

        var independent = migrated
        independent.videoCompressionMode = CompressionMode.manual.rawValue
        independent.videoManualBitrateMbps = 100
        independent.slowMotionCompressionMode = CompressionMode.auto.rawValue
        independent.slowMotionCompressionLevel = VideoCompression.high.rawValue
        independent.slowMotionManualBitrateMbps = 25
        let roundTripped = try JSONDecoder().decode(
            CameraPreset.self,
            from: JSONEncoder().encode(independent)
        )
        XCTAssertEqual(roundTripped.videoManualBitrateMbps, 100)
        XCTAssertEqual(roundTripped.slowMotionManualBitrateMbps, 25)
        XCTAssertNotEqual(roundTripped.videoCompressionMode, roundTripped.slowMotionCompressionMode)
        defaults.removePersistentDomain(forName: suiteName)
    }
}
