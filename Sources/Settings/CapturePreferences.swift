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
      SettingsSectionHeader(title: "Shutter & Timer")
      SettingsCard {
        if camera.captureMode == .photo {
          SettingsChoiceRow(
            title: "Photo Timer",
            subtitle: "Delay before taking a photo",
            symbol: "timer",
            selection: $photoShutterDelay,
            options: [(0, "Off"), (3, "3 sec"), (5, "5 sec"), (10, "10 sec")]
          )
          SettingsDivider()
          SettingsChoiceRow(
            title: "Burst Photos",
            subtitle: "Photos captured while holding shutter",
            symbol: "square.stack.3d.up.fill",
            selection: $burstCount,
            options: [(5, "5"), (10, "10"), (15, "15")]
          )
        } else {
          SettingsChoiceRow(
            title: "Recording Timer",
            subtitle: "Delay before recording starts",
            symbol: "timer",
            selection: $shutterDelay,
            options: [(0, "Off"), (3, "3 sec"), (5, "5 sec"), (10, "10 sec")]
          )
          SettingsDivider()
          SettingsToggleRow(
            title: "Lock Recording Controls",
            subtitle: "Hold shutter for one second to stop",
            isOn: $recordingLock,
            symbol: "lock.fill"
          )
        }
      }

      SettingsSectionHeader(title: "Zoom")
      SettingsCard {
        SettingsChoiceRow(
          title: "Zoom Speed",
          subtitle: "Drag sensitivity",
          symbol: "plus.magnifyingglass",
          selection: $zoomSpeed,
          options: [(0.5, "Slow"), (1.0, "Normal"), (1.5, "Fast")]
        )
        SettingsDivider()
        SettingsToggleRow(
          title: "Tap Zoom to Reset",
          subtitle: "Tap zoom control to return to 1×",
          isOn: $tapZoomReset,
          symbol: "arrow.counterclockwise"
        )
      }

      SettingsSectionHeader(title: "Feedback")
      SettingsCard {
        SettingsToggleRow(
          title: "Capture Haptics",
          subtitle: camera.captureMode == .photo
            ? "Feel a tap when taking a photo" : "Feel a tap when starting or stopping recording",
          isOn: $haptics,
          symbol: "waveform"
        )

        if haptics {
          SettingsDivider()
          SettingsChoiceRow(
            title: "Haptic Strength",
            subtitle: "Tap a strength to preview it",
            symbol: "hand.tap.fill",
            selection: $strength,
            options: ["Low", "Medium", "Strong"].map { ($0, $0) },
            onSelect: { CameraHaptics.preview(strength: $0) },
            firesActionOnReselect: true
          )
          .transition(.opacity.combined(with: .move(edge: .top)))
        }

        SettingsDivider()
        SettingsToggleRow(
          title: "Countdown Haptics",
          subtitle: "Optional feedback during shutter countdowns",
          isOn: $countdownHaptics,
          symbol: "metronome.fill"
        )
      }
      .animation(.easeInOut(duration: 0.18), value: haptics)

      SettingsSectionHeader(title: "Capture Behavior")
      SettingsCard {
        SettingsToggleRow(
          title: "Remember Last Camera Mode",
          subtitle: "Restore Video, Photo or Slo-Mo on next launch",
          isOn: $rememberCaptureMode,
          symbol: "clock.arrow.circlepath"
        )
        SettingsDivider()
        SettingsToggleRow(
          title: "Mirror Saved Selfies",
          subtitle: "Save front-camera media with the preview-style mirror",
          isOn: $mirrorSelfies,
          symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right"
        )
        SettingsDivider()
        SettingsActionRow(
          title: "Reset Exposure & White Balance",
          subtitle: "Return EV and WB to Auto",
          symbol: "arrow.counterclockwise"
        ) {
          camera.setExposureBias(0)
          camera.selectWhiteBalancePreset(.auto)
        }
      }
    }
    .navigationTitle("Capture")
    .navigationBarTitleDisplayMode(.inline)
  }
}
