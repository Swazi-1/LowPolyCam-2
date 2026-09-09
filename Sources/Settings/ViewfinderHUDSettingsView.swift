import SwiftUI

struct CameraHUDSettingsView: View {
    @ObservedObject var camera: CameraManager
    @AppStorage("cameraHUDEnabled") private var isHUDEnabled = true

    var body: some View {
        List {
            Section("HUD") {
                Toggle(isOn: $isHUDEnabled) {
                    SettingsToggleLabel(
                        symbol: "capsule.fill",
                        color: .blue,
                        title: "Show Camera HUD",
                        subtitle: "Show the in-camera information capsule."
                    )
                }

                NavigationLink {
                    CameraHUDContentSettingsView(camera: camera)
                } label: {
                    SettingsNavigationLabel(
                        symbol: "text.line.first.and.arrowtriangle.forward",
                        color: .purple,
                        title: "HUD Content & Style",
                        subtitle: "Choose information and text size"
                    )
                }
                .disabled(!isHUDEnabled)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Camera HUD")
        .navigationBarTitleDisplayMode(.large)
        .tint(.blue)
    }
}

private struct CameraHUDContentSettingsView: View {
    @ObservedObject var camera: CameraManager
    @AppStorage("cameraHUDResolution") private var hudResolution = true
    @AppStorage("cameraHUDFPS") private var hudFPS = true
    @AppStorage("cameraHUDRemaining") private var hudRemaining = true
    @AppStorage("cameraHUDWhiteBalance") private var hudWhiteBalance = false
    @AppStorage("cameraHUDBattery") private var hudBattery = true
    @AppStorage("cameraHUDStorage") private var hudStorage = false
    @AppStorage("cameraHUDDroppedFrames") private var hudDroppedFrames = false
    @AppStorage("thermalHUD") private var hudThermal = false
    @AppStorage("hudTextSize") private var hudTextSize = 10.0

    var body: some View {
        List {
            Section("MAIN INFO") {
                Toggle("Resolution", isOn: $hudResolution)
                if camera.captureMode != .photo {
                    Toggle("FPS", isOn: $hudFPS)
                }
                Toggle(camera.captureMode == .photo ? "Photos Remaining" : "Time Remaining", isOn: $hudRemaining)
                Toggle("White Balance", isOn: $hudWhiteBalance)
            }

            Section("DEVICE INFO") {
                Toggle("Battery", isOn: $hudBattery)
                Toggle("Free Storage", isOn: $hudStorage)
                Toggle("Thermal Status", isOn: $hudThermal)
                if camera.captureMode != .photo {
                    Toggle("Frame Gaps", isOn: $hudDroppedFrames)
                }
            }

            Section("HUD APPEARANCE") {
                Picker("Text Size", selection: $hudTextSize) {
                    Text("Compact").tag(10.0)
                    Text("Large").tag(12.0)
                }
                .pickerStyle(.menu)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Camera HUD")
        .navigationBarTitleDisplayMode(.large)
        .tint(.blue)
    }
}
