#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lowpolycam-state-tests.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT

swiftc -swift-version 5 \
  "$ROOT/Sources/Camera/BoundedInFlightGate.swift" \
  "$ROOT/Sources/Camera/CaptureConfigurationTransaction.swift" \
  "$ROOT/Sources/Camera/LongevityModeState.swift" \
  "$ROOT/Sources/Camera/RecoveryRetryState.swift" \
  "$ROOT/Sources/Camera/CameraRecoveryStore.swift" \
  "$ROOT/Tests/StateRegressionTests.swift" \
  -o "$BUILD_DIR/state-regressions"
"$BUILD_DIR/state-regressions"
