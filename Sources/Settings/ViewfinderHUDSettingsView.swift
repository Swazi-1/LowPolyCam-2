import SwiftUI

struct ViewfinderHUDSettingsView: View {
  @ObservedObject var camera: CameraManager
  @AppStorage("cameraGridEnabled") private var isGridEnabled = false
  @AppStorage("gridOpacity") private var gridOpacity = 1.0
  @AppStorage("levelMeterEnabled") private var isLevelMeterEnabled = true
  @AppStorage("centerCrosshair") private var centerCrosshair = false
  @AppStorage("keepScreenAwakeEnabled") private var keepScreenAwakeEnabled = false
  @AppStorage("cameraHUDEnabled") private var isHUDEnabled = true
  @AppStorage("cameraHUDResolution") private var hudResolution = true
  @AppStorage("cameraHUDFPS") private var hudFPS = true
  @AppStorage("cameraHUDRemaining") private var hudRemaining = true
  @AppStorage("cameraHUDWhiteBalance") private var hudWhiteBalance = false
  @AppStorage("cameraHUDBattery") private var hudBattery = false
  @AppStorage("cameraHUDStorage") private var hudStorage = false
  @AppStorage("cameraHUDDroppedFrames") private var hudDroppedFrames = false
  @AppStorage("cameraHUDAudioMeter") private var hudAudioMeter = false
  @AppStorage("thermalHUD") private var hudThermal = false
  @AppStorage("hudTextSize") private var hudTextSize = 10.0

  var body: some View {
    SettingsPage {
      SettingsSectionHeader(title: "Guides")
      SettingsCard {
        SettingsToggleRow(
          title: "Grid",
          subtitle: "Show composition grid",
          isOn: $isGridEnabled,
          symbol: "square.grid.3x3"
        )

        if isGridEnabled {
          SettingsSliderChildRow(
            title: "Grid Opacity",
            subtitle: "Adjust grid visibility",
            value: $gridOpacity,
            range: 0.2...1.0
          )
        }

        SettingsDivider()
        SettingsToggleRow(
          title: "Level",
          subtitle: "Show the live horizon level",
          isOn: $isLevelMeterEnabled,
          symbol: "viewfinder"
        )
        SettingsDivider()
        SettingsToggleRow(
          title: "Center Crosshair",
          subtitle: "Show a small center aiming mark",
          isOn: $centerCrosshair,
          symbol: "plus"
        )
      }
      .animation(.easeInOut(duration: 0.18), value: isGridEnabled)

      SettingsSectionHeader(title: "Camera HUD")
      SettingsCard {
        SettingsToggleRow(
          title: "Show Camera HUD",
          subtitle: "Live camera information between Flash and Settings",
          isOn: $isHUDEnabled,
          symbol: "capsule.fill"
        )

        if isHUDEnabled {
          Group {
            SettingsDivider()
            SettingsChoiceRow(
              title: "Text Size",
              subtitle: "HUD information size",
              symbol: "textformat.size",
              selection: $hudTextSize,
              options: [(10.0, "Compact"), (12.0, "Large")]
            )
            SettingsDivider()
            SettingsToggleRow(
              title: "Resolution", subtitle: "Show active capture resolution", isOn: $hudResolution,
              symbol: "rectangle.inset.filled")

            if camera.captureMode != .photo {
              SettingsDivider()
              SettingsToggleRow(
                title: "FPS", subtitle: "Show selected capture frame rate", isOn: $hudFPS,
                symbol: "speedometer")
            }

            SettingsDivider()
            SettingsToggleRow(
              title: "Remaining",
              subtitle: camera.captureMode == .photo
                ? "Estimate photos remaining" : "Estimate recording time remaining",
              isOn: $hudRemaining,
              symbol: "hourglass"
            )
            SettingsDivider()
            SettingsToggleRow(
              title: "White Balance", subtitle: "Show active white-balance preset",
              isOn: $hudWhiteBalance, symbol: "thermometer.medium")
            SettingsDivider()
            SettingsToggleRow(
              title: "Battery", subtitle: "Show battery percentage", isOn: $hudBattery,
              symbol: "battery.100percent")
            SettingsDivider()
            SettingsToggleRow(
              title: "Free Storage", subtitle: "Show available device storage", isOn: $hudStorage,
              symbol: "internaldrive")
            SettingsDivider()
            SettingsToggleRow(
              title: "Thermal Status", subtitle: "Show current thermal state", isOn: $hudThermal,
              symbol: "thermometer.high")

            if camera.captureMode != .photo {
              SettingsDivider()
              SettingsToggleRow(
                title: "Frame Gaps", subtitle: "Analyze the last saved clip for frame gaps",
                isOn: $hudDroppedFrames, symbol: "film.stack")
              SettingsDivider()
              SettingsToggleRow(
                title: "Audio Meter", subtitle: "Microphone level meter while recording",
                isOn: $hudAudioMeter, symbol: "waveform")
            }
          }
          .transition(.opacity.combined(with: .move(edge: .top)))
        }
      }
      .animation(.easeInOut(duration: 0.18), value: isHUDEnabled)

      SettingsSectionHeader(title: "Screen Behavior")
      SettingsCard {
        SettingsToggleRow(
          title: "Keep Screen Awake",
          subtitle: "Prevent Auto-Lock while LowPolyCam is open",
          isOn: $keepScreenAwakeEnabled,
          symbol: "display"
        )
      }
    }
    .navigationTitle("Viewfinder & HUD")
    .navigationBarTitleDisplayMode(.inline)
    .onChange(of: isHUDEnabled) { _ in camera.refreshAuxiliaryOutputs() }
    .onChange(of: hudAudioMeter) { _ in camera.refreshAuxiliaryOutputs() }
    .onChange(of: hudDroppedFrames) { _ in camera.refreshAuxiliaryOutputs() }
  }
}
