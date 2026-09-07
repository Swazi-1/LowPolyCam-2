#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

require() {
  local file="$1"
  local text="$2"
  grep -Fq "$text" "$file" || { echo "Missing settings wiring: $text ($file)" >&2; exit 1; }
}

# Capture-manager mutations must continue through the established safe paths.
require Sources/Settings/VideoSettingsView.swift 'camera.selectResolution(value)'
require Sources/Settings/VideoSettingsView.swift 'camera.selectFrameRate(value)'
require Sources/Settings/VideoSettingsView.swift 'camera.selectSlowMotionResolution(value)'
require Sources/Settings/VideoSettingsView.swift 'camera.selectSlowMotionFrameRate(value)'
require Sources/Settings/VideoSettingsView.swift 'camera.selectPhotoResolution(option)'
require Sources/Settings/VideoSettingsView.swift 'camera.videoCompression = $0'
require Sources/Settings/VideoSettingsView.swift 'camera.selectedVideoCodec = $0'
require Sources/Settings/VideoSettingsView.swift 'camera.photoFileFormat = $0'
require Sources/Settings/VideoSettingsView.swift 'camera.refreshPhotoResolutionForCurrentAspect()'
require Sources/Settings/QuickCameraSettings.swift 'camera.setVideoStabilizationEnabled(enabled)'
require Sources/Settings/CapturePreferences.swift 'CameraHaptics.preview(strength: $0)'
require Sources/Settings/CapturePreferences.swift 'camera.setExposureBias(0)'
require Sources/Settings/CapturePreferences.swift 'camera.selectWhiteBalancePreset(.auto)'
require Sources/Settings/RecordingExtrasSettings.swift 'camera.applyLongevityMode(enabled)'
require Sources/Settings/RecordingExtrasSettings.swift 'camera.refreshLiveMetrics()'
require Sources/Settings/ViewfinderHUDSettingsView.swift 'camera.refreshAuxiliaryOutputs()'
require Sources/Settings/VideoPresetsView.swift 'camera.applyQuickPreset(preview)'

# These persisted keys existed before the redesign and must not be renamed during UI work.
keys=(
  photoAspect shutterDelay photoShutterDelay burstCount hapticCaptureEnabled hapticStrength
  mirrorSelfies zoomSpeed tapZoomReset recordingLock countdownHaptics rememberCaptureMode
  cameraGridEnabled gridOpacity levelMeterEnabled centerCrosshair keepScreenAwakeEnabled
  cameraHUDEnabled cameraHUDResolution cameraHUDFPS cameraHUDRemaining cameraHUDWhiteBalance
  cameraHUDBattery cameraHUDStorage cameraHUDDroppedFrames cameraHUDAudioMeter thermalHUD hudTextSize
  splitMinutes longevityMode liveRecordingStats lowStorageWarning liveStatsSize liveStatsShowFPS
  liveStatsShowBitrate liveStatsShowDrops iconAppearance iconCustomRed iconCustomGreen iconCustomBlue
)
for key in "${keys[@]}"; do
  rg -q "@AppStorage\\(\"${key}\"\\)" Sources || {
    echo "Persisted setting key disappeared: $key" >&2
    exit 1
  }
done

# Confirm persisted settings still have their runtime consumers after the UI move.
require Sources/Camera/CameraView.swift '@AppStorage("shutterDelay")'
require Sources/Camera/CameraView.swift '@AppStorage("photoShutterDelay")'
require Sources/Camera/CaptureSettingsStore.swift 'defaults.integer(forKey: "burstCount")'
require Sources/Settings/CameraHaptics.swift 'defaults.string(forKey: "hapticStrength")'
require Sources/Camera/CameraView.swift '@AppStorage("mirrorSelfies")'
require Sources/Camera/CameraView.swift '@AppStorage("zoomSpeed")'
require Sources/Camera/CameraView.swift '@AppStorage("tapZoomReset")'
require Sources/Camera/CameraView.swift '@AppStorage("recordingLock")'
require Sources/Camera/CameraView.swift '@AppStorage("countdownHaptics")'
require Sources/Camera/CameraPreferenceStore.swift 'rememberCaptureMode = "rememberCaptureMode"'
require Sources/Camera/CameraView.swift '@AppStorage("cameraGridEnabled")'
require Sources/Camera/CameraView.swift '@AppStorage("gridOpacity")'
require Sources/Camera/CameraView.swift '@AppStorage("levelMeterEnabled")'
require Sources/Camera/CameraView.swift '@AppStorage("centerCrosshair")'
require Sources/Camera/CameraView.swift '@AppStorage("keepScreenAwakeEnabled")'
require Sources/Camera/CameraView.swift '@AppStorage("cameraHUDEnabled")'
require Sources/Camera/CameraHUD.swift '@AppStorage("cameraHUDBattery")'
require Sources/Camera/CameraHUD.swift '@AppStorage("cameraHUDStorage")'
require Sources/Camera/CaptureSettingsStore.swift 'defaults.bool(forKey: "cameraHUDAudioMeter")'
require Sources/Camera/CaptureSettingsStore.swift 'defaults.bool(forKey: "cameraHUDDroppedFrames")'
require Sources/Camera/CaptureSettingsStore.swift 'defaults.integer(forKey: "splitMinutes")'
require Sources/Camera/CameraView.swift '@AppStorage("liveRecordingStats")'
require Sources/Camera/CameraView.swift '@AppStorage("lowStorageWarning")'
require Sources/Settings/RecordingExtrasSettings.swift '@AppStorage("liveStatsSize")'
require Sources/Settings/RecordingExtrasSettings.swift '@AppStorage("liveStatsShowFPS")'
require Sources/Settings/RecordingExtrasSettings.swift '@AppStorage("liveStatsShowBitrate")'
require Sources/Settings/RecordingExtrasSettings.swift '@AppStorage("liveStatsShowDrops")'
require Sources/Settings/CameraTheme.swift '@AppStorage("iconAppearance")'
require project.yml 'iOS: "26.0"'

# Quick Controls and the detailed Viewfinder page intentionally mirror the exact same storage keys.
for key in cameraGridEnabled gridOpacity levelMeterEnabled; do
  grep -Fq "@AppStorage(\"$key\")" Sources/Settings/QuickCameraSettings.swift
  grep -Fq "@AppStorage(\"$key\")" Sources/Settings/ViewfinderHUDSettingsView.swift
done

# The new interface-style key must be shared by the main Settings screen and Appearance page.
grep -Fq '@AppStorage("settingsInterfaceStyle")' Sources/Settings/VideoSettingsView.swift
grep -Fq '@AppStorage("settingsInterfaceStyle")' Sources/Settings/AppearanceSettingsView.swift

echo "Settings regression checks passed"
