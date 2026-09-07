#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
build_directory="$(mktemp -d)"
trap 'rm -f "$build_directory/recording-regressions"; rmdir "$build_directory"' EXIT
swiftc \
  Sources/Camera/ClipFrameGapCounter.swift \
  Sources/Camera/RecordingLifecycle.swift \
  Sources/Camera/CaptureRequestGate.swift \
  Sources/Camera/CameraRecoveryStore.swift \
  Tests/RecordingRegressionTests.swift \
  -o "$build_directory/recording-regressions"
"$build_directory/recording-regressions"
