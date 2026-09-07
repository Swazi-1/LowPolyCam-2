# LowPolyCam

SwiftUI camera app targeting **iOS 26 and newer** (iOS 26/27 policy). See [FIXES.md](FIXES.md) for the current lens-handoff, Video flip, white-balance, and verification notes.

## Build from GitHub Actions

Open **Actions**, select **Build iOS IPA**, choose **Run workflow**, and download
the `LowPolyCam-unsigned-ipa` artifact when the run finishes.

The generated IPA is unsigned. It must be signed with your own Apple developer
identity or a sideloading tool before it can be installed on an iPhone.

The workflow runs the portable zoom/recording/settings regression checks before building.
An Xcode build and an iPhone camera test are separate checks; building successfully
does not verify physical-lens smoothness or iOS beta camera behavior.

## Open locally on macOS

Install XcodeGen, then run:

```sh
brew install xcodegen
xcodegen generate
open LowPolyCam.xcodeproj
```

Run the regression checks on a Mac with Xcode's command-line tools:

```sh
bash scripts/run-zoom-regressions.sh
bash scripts/run-recording-regressions.sh
bash scripts/run-settings-regressions.sh
```

For CI-style compilation after `xcodegen generate`, build the `LowPolyCam` scheme
for `iphoneos` with code signing disabled.
