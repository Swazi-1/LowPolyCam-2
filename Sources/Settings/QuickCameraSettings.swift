import SwiftUI

struct QuickControlsSettingsView: View {
    @ObservedObject var camera: CameraManager
    @AppStorage("cameraGridEnabled") private var grid = false
    @AppStorage("gridOpacity") private var gridOpacity = 1.0
    @AppStorage("levelMeterEnabled") private var level = true
    @AppStorage("centerCrosshair") private var crosshair = false
    @AppStorage("appColorScheme") private var appColorScheme = "system"

    var body: some View {
        List {
            Section("CAMERA") {
                Toggle(
                    isOn: Binding(
                        get: { camera.isVideoStabilizationEnabled },
                        set: { camera.setVideoStabilizationEnabled($0) }
                    )
                ) {
                    SettingsToggleLabel(
                        symbol: "dot.radiowaves.left.and.right",
                        color: .green,
                        title: "Stabilization",
                        subtitle: "Reduce camera shake in Video mode."
                    )
                }
            }

            Section("COMPOSITION") {
                Toggle(isOn: $grid) {
                    SettingsToggleLabel(
                        symbol: "grid",
                        color: .blue,
                        title: "Grid",
                        subtitle: "Show composition guides in the viewfinder."
                    )
                }

                if grid {
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

                Toggle(isOn: $level) {
                    SettingsToggleLabel(
                        symbol: "gyroscope",
                        color: .orange,
                        title: "Level",
                        subtitle: "Show the horizon level meter."
                    )
                }

                Toggle(isOn: $crosshair) {
                    SettingsToggleLabel(
                        symbol: "plus",
                        color: .gray,
                        title: "Center Crosshair",
                        subtitle: "Show a marker at the center of the frame."
                    )
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Quick Controls")
        .navigationBarTitleDisplayMode(.large)
        .tint(.blue)
        .preferredColorScheme(resolvedColorScheme(appColorScheme))
    }
}
