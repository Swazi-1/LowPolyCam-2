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

struct CameraHUDContentSettingsView: View {
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
    @AppStorage("audioLevelMeter") private var audioLevelMeter = AudioLevelMeterMode.bars.rawValue
    @AppStorage("cleanPreviewGesture") private var cleanPreviewGesture = CleanPreviewGesture.twoFingerTap.rawValue

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

            Section {
                Picker("Audio Level Meter", selection: $audioLevelMeter) {
                    ForEach(AudioLevelMeterMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: audioLevelMeter) { _, rawValue in
                    if let mode = AudioLevelMeterMode(rawValue: rawValue) {
                        camera.setAudioLevelMeterMode(mode)
                    }
                }

                Picker("Clean Preview Gesture", selection: $cleanPreviewGesture) {
                    ForEach(CleanPreviewGesture.allCases) { gesture in
                        Text(gesture.rawValue).tag(gesture.rawValue)
                    }
                }
                .pickerStyle(.menu)
            } header: {
                Text("CAPTURE HUD")
            } footer: {
                Text("The audio meter reads the authorized microphone data output and appears only while recording. Clean Preview hides non-essential UI temporarily; capture and stop remain available.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("HUD Content & Style")
        .navigationBarTitleDisplayMode(.large)
        .tint(.blue)
    }
}
