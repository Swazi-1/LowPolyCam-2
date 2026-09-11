import SwiftUI

struct QuickControlsSettingsView: View {
    @ObservedObject var camera: CameraManager
    @AppStorage("cameraGridEnabled") private var grid = false
    @AppStorage("gridOpacity") private var gridOpacity = 1.0
    @AppStorage("gridStyle") private var gridStyle = GridStyle.ruleOfThirds.rawValue
    @AppStorage("frameGuidesEnabled") private var frameGuidesEnabled = false
    @AppStorage("levelMeterEnabled") private var level = false
    @AppStorage("centerCrosshair") private var crosshair = false
    @AppStorage("cleanPreviewGesture") private var cleanPreviewGesture = CleanPreviewGesture.doubleTap.rawValue

    var body: some View {
        List {
            Section("COMPOSITION") {
                HapticFreeSettingsToggle(isOn: $grid) {
                    SettingsToggleLabel(
                        symbol: "square.grid.3x3",
                        color: .blue,
                        title: "Grid",
                        subtitle: "Show composition guides over the camera preview."
                    )
                }

                if grid {
                    Picker("Grid Style", selection: $gridStyle) {
                        ForEach(GridStyle.allCases) { style in
                            Text(style.rawValue).tag(style.rawValue)
                        }
                    }
                    .pickerStyle(.menu)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Grid Opacity")
                            Spacer()
                            Text("\(Int(gridOpacity * 100))%")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $gridOpacity, in: 0.2...1)
                    }
                    .padding(.vertical, 4)
                }

                HapticFreeSettingsToggle(isOn: $frameGuidesEnabled) {
                    SettingsToggleLabel(
                        symbol: "viewfinder",
                        color: .purple,
                        title: "Safe Frame Guides",
                        subtitle: "Show a dashed inner frame for cleaner composition."
                    )
                }

                HapticFreeSettingsToggle(isOn: $level) {
                    SettingsToggleLabel(
                        symbol: "gyroscope",
                        color: .orange,
                        title: "Level",
                        subtitle: "Show the horizon level meter."
                    )
                }

                HapticFreeSettingsToggle(isOn: $crosshair) {
                    SettingsToggleLabel(
                        symbol: "plus",
                        color: .gray,
                        title: "Center Crosshair",
                        subtitle: "Show a marker at the center of the frame."
                    )
                }
            }

            Section {
                Picker("Clean Preview Gesture", selection: $cleanPreviewGesture) {
                    ForEach(CleanPreviewGesture.allCases) { gesture in
                        Text(gesture.rawValue).tag(gesture.rawValue)
                    }
                }
                .pickerStyle(.menu)
            } header: {
                Text("PREVIEW")
            } footer: {
                Text("Clean Preview hides the HUD and controls while keeping one persistent shutter row. Use the configured gesture on the preview to toggle it.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Quick Controls")
        .navigationBarTitleDisplayMode(.large)
        .tint(.blue)
    }
}
