#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lowpolycam-zoom-tests.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT

swiftc -swift-version 5 -O \
  "$ROOT/Sources/Camera/LatestValueMailbox.swift" \
  "$ROOT/Sources/Camera/ZoomRoutingPolicy.swift" \
  "$ROOT/Sources/Camera/PreviewTransitionStateMachine.swift" \
  "$ROOT/Sources/Camera/CameraLevelMath.swift" \
  "$ROOT/Tests/ZoomRegressionTests.swift" \
  -o "$BUILD_DIR/zoom-regressions"
"$BUILD_DIR/zoom-regressions"
