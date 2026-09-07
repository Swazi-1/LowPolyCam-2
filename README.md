# LowPolyCam

SwiftUI camera app targeting iOS 15 and newer, with availability-guarded APIs for newer iOS versions. See [FIXES.md](FIXES.md) for the zoom fixes and outstanding iPhone validation.

## Build from GitHub Actions

Open **Actions**, select **Build iOS IPA**, choose **Run workflow**, and download
the `LowPolyCam-unsigned-ipa` artifact when the run finishes.

The generated IPA is unsigned. It must be signed with your own Apple developer
identity or a sideloading tool before it can be installed on an iPhone.

The workflow runs the portable zoom/recording regression checks before building.
An Xcode build and an iPhone camera test are separate checks; building successfully
does not verify zoom smoothness or iOS beta camera behavior.

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
```
