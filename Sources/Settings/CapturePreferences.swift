import SwiftUI

struct CapturePreferencesView: View {
    @ObservedObject var camera: CameraManager
    @AppStorage("shutterDelay") private var shutterDelay = 0
    @AppStorage("photoShutterDelay") private var photoShutterDelay = 0
    @AppStorage("burstCount") private var burstCount = 5
    @AppStorage("hapticCaptureEnabled") private var haptics = true
    @AppStorage("hapticStrength") private var strength = "Medium"
    @AppStorage("mirrorSelfies") private var mirrorSelfies = false
    @AppStorage("zoomSpeed") private var zoomSpeed = 1.0
    @AppStorage("tapZoomReset") private var tapZoomReset = true
    @AppStorage("recordingLock") private var recordingLock = false
    @AppStorage("countdownHaptics") private var countdownHaptics = false
    @AppStorage("rememberCaptureMode") private var rememberCaptureMode = false

    var body: some View {
        SettingsPage {
            SettingsCard(title: "Shutter & Timer", symbol: "timer") {
                if camera.captureMode == .photo {
                    ThemeMenu(
                        title: "Photo Timer",
                        selection: $photoShutterDelay,
                        options: [(0, "Off"), (3, "3 sec"), (5, "5 sec"), (10, "10 sec")]
                    )
                    SettingsDivider()
                    ThemeMenu(
                        title: "Burst Photos",
                        selection: $burstCount,
                        options: [(5, "5"), (10, "10"), (15, "15")]
                    )
                    Text("Hold the shutter to start a burst. Photos keep saving in the background.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ThemeMenu(
                        title: "Recording Timer",
                        selection: $shutterDelay,
                        options: [(0, "Off"), (3, "3 sec"), (5, "5 sec"), (10, "10 sec")]
                    )
                    SettingsDivider()
                    SettingsToggleRow(
                        title: "Lock Recording Controls",
                        subtitle: "When locked, hold the shutter for one second to stop",
                        isOn: $recordingLock
                    )
                }
            }

            SettingsCard(title: "Zoom", symbol: "plus.magnifyingglass") {
                ThemeMenu(
                    title: "Zoom Speed",
                    selection: $zoomSpeed,
                    options: [(0.5, "Slow"), (1.0, "Normal"), (1.5, "Fast")]
                )
                Text("Changes drag sensitivity only; physical lens-switch speed is controlled by the camera hardware.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                SettingsDivider()
                SettingsToggleRow(
                    title: "Tap Zoom to Reset",
                    subtitle: "Tap the zoom control to return to 1×",
                    isOn: $tapZoomReset
                )
            }

            SettingsCard(title: "Feedback", symbol: "waveform") {
                SettingsToggleRow(
                    title: "Capture Haptics",
                    subtitle: camera.captureMode == .photo ? "Feel a tap when taking a photo" : "Feel a tap when starting or stopping recording",
                    isOn: $haptics
                )
                SettingsDivider()
                ThemeMenu(
                    title: "Haptic Strength",
                    selection: $strength,
                    options: ["Low", "Medium", "Strong"].map { ($0, $0) },
                    onSelect: { CameraHaptics.preview(strength: $0) },
                    firesActionOnReselect: true
                )
                .disabled(!haptics)
                if !haptics {
                    Text("Turn Capture Haptics on to preview strength.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                SettingsDivider()
                SettingsToggleRow(
                    title: "Countdown Haptics",
                    subtitle: "Optional feedback during shutter countdowns",
                    isOn: $countdownHaptics
                )
            }

            SettingsCard(title: "Capture Behavior", symbol: "camera.badge.ellipsis") {
                SettingsToggleRow(
                    title: "Remember Last Camera Mode",
                    subtitle: "Restore Video, Photo or Slo-Mo on next launch",
                    isOn: $rememberCaptureMode
                )
                SettingsDivider()
                SettingsToggleRow(
                    title: "Mirror Saved Selfies",
                    subtitle: "Save front-camera media with the preview-style mirror",
                    isOn: $mirrorSelfies
                )
                SettingsDivider()
                Button {
                    camera.setExposureBias(0)
                    camera.selectWhiteBalancePreset(.auto)
                } label: {
                    Label("Reset Exposure & White Balance", systemImage: "arrow.counterclockwise")
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
        }
        .navigationTitle("Capture")
        .navigationBarTitleDisplayMode(.inline)
    }
}
