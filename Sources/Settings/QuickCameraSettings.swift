import SwiftUI

struct QuickCameraSettings: View {
    @ObservedObject var camera: CameraManager
    @AppStorage("cameraGridEnabled") private var grid = false
    @AppStorage("gridOpacity") private var opacity = 1.0
    @AppStorage("levelMeterEnabled") private var level = true
    @Environment(\.cameraTint) private var theme
    var body: some View {
        SettingsCard(title: "Quick Controls", symbol: "slider.horizontal.3") {
            if camera.captureMode == .video {
                SettingsToggleRow(title: "Stabilization", subtitle: "Reduce camera shake", isOn: Binding(get: { camera.isVideoStabilizationEnabled }, set: camera.setVideoStabilizationEnabled))
                SettingsDivider()
            }
            SettingsToggleRow(title: "Grid", subtitle: "Rule-of-thirds composition guides", isOn: $grid)
            if grid {
                HStack {
                    Text("Opacity").font(.caption)
                    Slider(value: $opacity, in: 0.2...1).accessibilityLabel("Grid opacity")
                    Text("\(Int(opacity * 100))%").font(.caption.monospacedDigit()).frame(width: 36)
                }.tint(theme)
            }
            SettingsDivider()
            SettingsToggleRow(title: "Level", subtitle: "Keep the horizon straight", isOn: $level)
        }
    }
}
