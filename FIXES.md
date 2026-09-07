# LowPolyCam bug-fix review — 7 September 2026

Reviewed the supplied `LowPolyCam-2-main (2).zip`, including capture, recording, photo processing, permissions, settings, and UI code. Changes are based on identifiable code paths; this is not a claim that every possible camera or beta-OS bug has been eliminated.

## Zoom and physical lenses

- Removed the explicit policy that kept the current physical lens throughout a held 4K60/Slo-Mo drag. When both physical lenses support the selected resolution/FPS, crossing 1x now requests the Wide camera during the drag.
- Replaced one queued operation per drag sample with a thread-safe single pending value. Updates arriving during a slow input handoff replace older pending positions. The consumer yields between updates so recording and lifecycle operations can run.
- Interactive zoom applies the latest factor directly. Lens-button taps still use an animated ramp. Previously every drag sample restarted a ramp, even though the caller asked for no animation.
- Added a small reverse-direction boundary dead band to avoid repeatedly exchanging inputs when a finger jitters around 1x. Snapping happens before final route selection at finger-up, not on every drag sample or inside the new lens configuration.
- Removed the full mode-transition overlay from zoom handoffs, which could interrupt the held gesture.
- Camera/mode changes and app suspension invalidate the gesture. Canceled gestures discard their old drag origin. Zoom work no longer supersedes a newer unrelated configuration token.
- High-bandwidth zoom domains use physical devices that pass the existing exact resolution/FPS/codec selection. A virtual camera's range no longer advertises an unavailable physical lens in those domains.
- Slo-Mo digital zoom stays usable during recording. A movie retains its current physical input; this change does not add seamless physical input replacement in the middle of one movie.

## Other fixes

- Manual white balance checks custom-gain support and clamps finite RGB gains on every OS version. Removed an unchecked temperature/tint setter that could raise an Objective-C exception.
- Photo dimension limits are checked against the new active format when changing modes or lenses.
- Photo processing reserves its pending save and requests background time before cropping/encoding, rather than only when the Photos import starts.
- Recovery refuses missing sources and preserves stable URLs on failed retries. Save errors only say a recording is in Recovery when preservation actually succeeded.
- Compressed-video frame diagnostics retain timestamp lookahead across batches, avoiding false dropped-frame counts caused by decode-order delivery.
- Preview rotation observes the rotation coordinator while idle. Older OS versions use orientation fallbacks. Focus gestures ignore photo letterboxing, and a rejected focus lock no longer leaves its indicator stuck.
- A held burst cannot repeatedly restart after reaching its configured count. Interrupted presses cancel correctly. Delayed video recording displays its countdown.
- Permission state remains stable until the sequence of system permission prompts finishes.
- Longevity-mode configuration invalidates old zoom work and captures a configuration snapshot. Restarting an existing camera manager no longer silently resets its requested zoom while retaining the old hardware zoom.

## Compatibility and verification

- Minimum deployment target is iOS 15.0. Photo-dimension APIs (iOS 16), RotationCoordinator/rotation-angle APIs (iOS 17), metadata (iOS 18), and newer SwiftUI navigation/layout APIs have fallbacks or availability guards.
- Optional sample-buffer monitoring outputs are disabled below iOS 16, where their simultaneous use with movie-file capture is unsupported. Core photo and movie capture remain available.
- The existing build workflow still uses Xcode 26; no iOS 27-only API was introduced.
- Local validation: all 42 Swift source/test files parse without syntax errors using the Swift tree-sitter grammar; shell-script syntax, project/resource configuration, archive integrity, and the changes against the original ZIP are checked separately.
- **Not run here:** Swift regression executables, Xcode compilation, signing/installation, or physical camera tests. This Windows environment has no Swift compiler, Xcode, or connected iPhone camera. The included workflow runs both regression suites before its iOS build when uploaded and triggered.

## Required iPhone checks

1. On the iPhone 11/iOS 27 beta, preview 4K60 and drag from 0.5x through 1x to 3x without lifting. Check that the handoff occurs while held and reversing through 1x does not repeatedly switch lenses.
2. Repeat at each supported Slo-Mo rate. If 0.5x is absent at a particular rate, check the device's exact physical Ultra Wide formats; the app must not pretend an unsupported lens/FPS combination exists.
3. Record 4K60 and 120/240-fps Slo-Mo on each supported lens; zoom during recording, stop, and inspect saved resolution, frame cadence, duration, playback, and audio. Physical lens changes during one recording remain restricted.
4. Rapidly reverse a drag, change mode, open Control Center, and return. Verify no old zoom continues and Record/Stop remain responsive. Repeat with optional monitoring off and on.
5. Rotate while idle and recording; switch cameras; test Auto/manual WB, Photo-to-Slo-Mo transitions, short/held/canceled burst presses, delayed video, and backgrounding immediately after a photo.
6. Exercise a failed Photos save/retry and confirm the retained recording is listed and recoverable. Verify first-launch permission prompts and an iOS 15 device build/run separately.

## API references used during review

- [Apple: zoom ramps](https://developer.apple.com/documentation/avfoundation/avcapturedevice/ramp(tovideozoomfactor:withrate:))
- [Apple: maximum photo dimensions](https://developer.apple.com/documentation/avfoundation/avcapturephotooutput/maxphotodimensions)
- [Apple: white-balance temperature/tint setter](https://developer.apple.com/documentation/avfoundation/avcapturedevice/setwhitebalancemodelocked(whitebalancetemperatureandtintvalues:handler:))
- [Apple: camera capture changes in iOS 16](https://developer.apple.com/videos/play/wwdc2022/110429/)
- [Apple: iOS 27 beta release notes](https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-27-release-notes)
