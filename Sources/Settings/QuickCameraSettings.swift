import SwiftUI

struct QuickCameraSettings: View {
  @ObservedObject var camera: CameraManager
  @AppStorage("cameraGridEnabled") private var grid = false
  @AppStorage("gridOpacity") private var opacity = 1.0
  @AppStorage("levelMeterEnabled") private var level = true

  var body: some View {
    SettingsCard {
      if camera.captureMode == .video {
        SettingsToggleRow(
          title: "Stabilization",
          subtitle: "Reduce camera shake",
          isOn: Binding(
            get: { camera.isVideoStabilizationEnabled },
            set: { enabled in
              guard enabled != camera.isVideoStabilizationEnabled else { return }
              camera.setVideoStabilizationEnabled(enabled)
            }
          ),
          symbol: "gyroscope"
        )
        SettingsDivider()
      }

      SettingsToggleRow(
        title: "Grid",
        subtitle: "Show composition grid",
        isOn: $grid,
        symbol: "square.grid.3x3"
      )

      if grid {
        SettingsSliderChildRow(
          title: "Grid Opacity",
          subtitle: "Adjust grid visibility",
          value: $opacity,
          range: 0.2...1.0
        )
      }

      SettingsDivider()

      SettingsToggleRow(
        title: "Level",
        subtitle: "Show horizon level",
        isOn: $level,
        symbol: "viewfinder"
      )
    }
    .animation(.easeInOut(duration: 0.18), value: grid)
  }
}
