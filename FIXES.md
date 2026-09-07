# LowPolyCam handoff implementation — 7 September 2026

This source applies the supplied Sol handoff to the current edited LowPolyCam baseline. It intentionally targets iOS 26/27 only and preserves the existing recording lifecycle, zoom routing policy, white-balance safety, recovery behavior, Photo resolution policy, and native 4K60/HFR capture architecture.

## Physical lens and preview handoffs

- Added an identity-based preview transition state machine and main-thread transition controller. Old asynchronous completions cannot dismiss a newer cover, and camera/lifecycle invalidation cancels stale transition ownership.
- Replaced per-handoff snapshot allocation with one reusable preview-only `UIVisualEffectView` plus a subtle tonal cover. The lens handoff uses a short blur-in, a minimum covered interval, a bounded preview-readiness heuristic, a smooth blur-out, and a 1-second watchdog.
- The blur is entirely inside `PreviewView`; it is not a capture output and therefore is not encoded into saved photos or movies.
- Lens covers no longer reuse the broad `isPreviewTransitioning` interaction lock. A held zoom drag can continue publishing the newest value while the physical sensor/input swap is covered.
- Zoom mailbox ownership is asynchronous now: a handoff releases the consumer exactly once after safe hardware commit/failure, while incoming drag values continue replacing one latest pending value. A reverse request can reuse/replace the existing cover instead of building a queue of stale lens swaps.
- Record presses received during a real idle handoff are retained as one pending intent and executed after the hardware reaches a stable committed target.
- Preview readiness deliberately does **not** claim a private/exact first-frame callback. It validates the committed input identity plus `AVCaptureVideoPreviewLayer.isPreviewing`, gives Core Animation display opportunities, and relies on the watchdog if readiness never appears.

## Video flip and first-use work

- Added a session-queue-owned capability cache for stable device discovery, format inventories, exact Video/Slo-Mo selector results, supported menu choices, and reusable selector work. Dynamic zoom/WB/readiness facts are still revalidated against the active format.
- `configureCurrentMode(Video)` and `configureCurrentMode(Slo-Mo)` now resolve/apply through their existing selectors once instead of performing the same discovery/selection before calling the apply path again.
- Successful front/back switching publishes the resolved active mode state directly instead of immediately running a full cross-mode capability rescan. Failure still rolls the UI/hardware state back and refreshes the previous state.
- Reuses a small bounded cache of `AVCaptureDeviceInput` objects on the serial session queue. The cache is invalidated on rebuild, media/device topology change, and recovery paths.
- Input replacement no longer rewrites `activeFormat` merely because the input changed. Frame durations and connection-dependent settings are still revalidated after input installation.
- HDR, distortion correction, zoom, photo-dimension limits, and movie-output configuration retain their correctness checks while avoiding writes when the active value already matches.
- Full-resolution Photo policy is preserved. Photo format candidates are cached by device; no lower-quality still format was introduced as a speed shortcut.

## White balance

- Preserved finite RGB gain validation and hardware clamping.
- Verified Auto and manual no-op paths avoid unnecessary device writes when the actual hardware mode/gains already match.
- Same-device preset changes stay WB-only; they do not run the full session/format pipeline.
- A virtual-to-physical input change required for manual WB uses the same transition coordinator, suppresses duplicate WB synchronization during the swap, then applies the requested WB exactly once through the existing completion-owned operation.

## iOS 26/27 policy

- Minimum deployment target is **iOS 26.0**.
- Removed the compatibility-only legacy preview/capture rotation path and uses typed `AVCaptureDevice.RotationCoordinator` directly.
- Uses `supportedMaxPhotoDimensions` / `maxPhotoDimensions` directly and removes the old below-iOS-16 monitoring compatibility gate while retaining the real HFR/topology restrictions.
- Removed iOS 15 SwiftUI fallbacks for navigation/layout and the now-obsolete iOS 18 metadata guard.
- No iOS 27-only API was added, so iOS 26 remains the deployment floor.

## Debug timing

Debug builds include `Logger`/`os_signpost` instrumentation for preview-transition request/cover/commit/readiness and the hardware configuration path, including input creation, device lock, format writes, photo-limit writes, session commit, and handoff duration. This is diagnostic timing only; it does not log camera images.

## Portable verification performed in this package

- `bash scripts/run-zoom-regressions.sh`
- `bash scripts/run-recording-regressions.sh`
- Swift parser pass across every `.swift` file in `Sources` and `Tests` using Swift 6.2.1.
- ZIP integrity/content validation is performed when the deliverable is packaged.

The zoom regression suite includes transition ownership checks: stale A cannot dismiss B, target identity is required, unbound targets bind only at commit, and cancel ownership releases once. Existing mailbox tests continue to cover latest-value backpressure and held-drag route changes.

## Requires macOS / iPhone validation

This source package can be syntax/regression validated on non-macOS hosts, but Apple SDK type/concurrency validation requires Xcode and physical smoothness requires the target device. On an iPhone 11/iOS 27 beta, specifically verify:

1. Cold Photo, rear 4K60, and every supported Slo-Mo rate: hold a 0.5x -> 1x -> 2x -> 0.5x drag, then repeat it five times. The cold physical handoff should be covered without a clear freeze/black flash and the finger must remain responsive.
2. Auto -> first manual WB -> same preset -> another preset -> Auto, followed immediately by lens zoom. Check that WB settles once and no stale transition remains.
3. Video front/back at supported 720p/1080p/4K and every frame-rate choice exposed by the current camera. Compare first and repeated timings with the already-fast Slo-Mo path.
4. Reverse a drag during the blur; flip/mode/record at the handoff boundary; interrupt with Control Center, lock/background, then return. Verify no stuck cover, no stale zoom backlog, and preserved useful zoom state.
5. Record/stop on every supported tested path and inspect saved dimensions, cadence, codec, audio, duration, and playback. The preview blur must never appear in media.
6. Test Reduce Motion, optional monitoring off/on, and a warm device. Unsupported Ultra Wide HFR combinations must stay unavailable rather than being fabricated.

## 2026-09-07 — iOS Camera-style physical lens transition tuning
- Physical lens/WB input handoffs now use a scene-preserving blur instead of the dark Chrome material cover.
- The outgoing preview is reduced to a tiny 12×20 scene plate plus an average scene color, then enlarged under the blur so the sensor gap keeps the outgoing scene tone instead of falling to black. UIKit-incomplete/near-empty captures are rejected and fall back to the live blur.
- 4K60/Slo-Mo/Photo physical handoffs begin only after the optical cover has had two 60 Hz display opportunities; reverse requests already under cover remain immediate.
- The incoming lens is revealed underneath the blur and then sharpened over a short dissolve, matching the observed iOS Camera transition shape more closely.
- Normal virtual-camera zoom paths (for example supported 1080p rear zoom) do not create a physical-lens transition and remain uncovered.

### 2026-09-07 — 4K60 handoff critical path + Level Meter
- Rear 4K60 physical lens handoffs now announce the committed sensor to the preview before refreshing recorder-only movie connection settings/stabilization. Record taps remain serialized behind that preparation, and recording start still re-validates the exact output connection.
- Physical input replacement no longer invalidates the movie settings signature solely because topology changed; the actual new connection settings are inspected and repaired when needed.
- Added the required Motion usage description for the Core Motion level meter.
- Level Meter now uses continuous cardinal-folded roll math: horizontal/level at 0/90/180/270 degrees without the old ~45-degree snap, hides when motion roll is genuinely unavailable instead of showing a fake straight line, and tolerates brief invalid samples without resetting.

### Level Meter launch-state sync
- Fixed a launch-only state mismatch where `levelMeterEnabled` could restore as ON while the runtime Core Motion monitor stayed unavailable until the toggle was cycled.
- CameraLevelHost now derives monitoring from one `enabled && sceneActive` lifecycle identity, avoiding first-appearance/AppStorage/scene-phase ordering races.
- Added a bounded startup retry for a silent first Core Motion activation. Retries stop as soon as any real `CMDeviceMotion` sample arrives and are cancelled immediately on disable/background/disappear.
- Existing level math, invalid-orientation handling, 30 Hz update rate, and saved toggle behavior are unchanged.


### 2026-09-07 — Full Settings UI redesign
- Rebuilt the main Settings screen around the approved compact card layout: active camera summary, Light/Dark/System selector, two-column mode-specific quality controls, grouped Quick Controls, and two-column navigation tiles.
- Video/Slo-Mo quality buttons remain capability-driven. Resolution/FPS still call the established CameraManager selection methods exactly once; Codec/Compression keep their existing validated reconfiguration/rollback paths.
- Photo keeps the maximum-quality resolution policy and existing Photo resolution selector; Aspect and HEIC/JPEG are now direct card controls.
- Grid Opacity and Haptic Strength are dependent rows that collapse when their parent setting is off. HUD child choices collapse when the HUD is hidden without deleting their stored values.
- Restyled Capture, Viewfinder & HUD, Advanced Recording, Live Stats, Video Presets, Appearance, and Recovery to the same card/section language using native SwiftUI controls and SF Symbols.
- Added a Settings-only Light/Dark/System preference while leaving the camera viewfinder's deliberate dark presentation unchanged.
- Preserved all existing persisted setting keys so an update does not reset user preferences.
- Preserved special side effects: Stabilization uses CameraManager, Longevity uses applyLongevityMode, Live Stats/HUD monitoring refreshes remain explicit, Photo aspect refreshes the resolution catalog, Mirror Selfies uses the existing movie-output refresh observer, and Haptic Strength can still preview on reselect.
- Added scripts/run-settings-regressions.sh and wired it into GitHub Actions to guard the critical setting-to-engine routes and persisted keys.

### 2026-09-07 — 4K60 held-zoom reveal, Level startup health, Settings QA polish
- Physical-lens handoffs now reconcile the newest same-gesture zoom value on the newly committed sensor before the optical cover is allowed to sharpen. Rear 4K60 therefore no longer intentionally reveals the boundary 1x value and then catches up to the finger afterward.
- If the newest held-drag value has already reversed across the physical lens boundary, the current cover is retained and ownership chains directly into the replacement lens handoff instead of exposing the temporary sensor for a clear frame.
- Rear 4K60 movie-output/stabilization preparation is deferred until the interactive zoom mailbox is idle. Recording start still performs its normal exact connection/settings validation, and stale/device-mismatched preparation is discarded.
- Level Meter Core Motion delivery now uses a dedicated serial operation queue. Startup is considered healthy only after a valid gravity-derived level sample, with bounded startup recovery and a freshness watchdog for a stream that reports active but stops delivering useful motion updates.
- Restored the Accent Preview to Appearance and removed the duplicate Light/Dark/System selector from that submenu. Interface style remains available on the main Settings screen.
- Added a contrast-safe accent-as-text variant for pale/custom themes while preserving the exact selected accent for fills, toggles, preview colors and selected backgrounds.
- Settings selection labels are single-line/tightening rather than mid-word hyphenated, and navigation tiles prioritize text width so labels such as Medium, Viewfinder & HUD and Advanced Recording do not split or truncate at normal iPhone widths.
- Root mode names use natural capitalization and supported resolution choices are presented 720p -> 1080p -> 4K while remaining capability-driven.
- Added portable regressions for pre-reveal latest-value reconciliation, stale/new zoom generations, and Level Meter startup/stream-health policy.
