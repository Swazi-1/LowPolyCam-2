# LowPolyCam v5.0.12

This archive is the v5.0.11 beta source with the v5 release-closure pass applied.

## Included

- Centralized preferences schema and invalid-value migration.
- Request-guarded asynchronous camera capability snapshots for Settings.
- Final video/photo media validation before Photos import.
- Photo and video Recovery preservation, retry, share, and confirmed delete actions.
- Split-recording session manifests with segment metadata.
- Explicit audio state in the camera HUD and recording settings.
- Diagnostic-log sharing, archived-log deletion, and privacy disclosure.
- Unit-test target plus CI build, test, plist, bundle, arm64, IPA, and checksum checks.
- Motion usage description required by the horizon level meter.
- Native launch-screen background asset and dead declaration cleanup.
- Xcode 26/Swift 6 CoreMedia format-description cast fix.

## Version

- Marketing version: 5.0.12
- Build: 517
- Deployment target: iOS 26+

## Validation boundary

The source and package structure were checked on Windows. Xcode, xcodebuild, XcodeGen, and an iPhone were not available in the packaging environment, so the actual Apple build, signing, simulator test run, and iPhone 11 runtime acceptance still belong on the macOS/iPhone release gate.
