import SwiftUI

struct CameraHUDSettingsView: View {
    @ObservedObject var camera: CameraManager
    @AppStorage("cameraHUDEnabled") private var isHUDEnabled = true
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
    @AppStorage("audioPeakHold") private var audioPeakHold = true
    @AppStorage("cameraHUDLens") private var hudLens = false

    var body: some View {
        List {
            Section("HUD") {
                HapticFreeSettingsToggle(isOn: $isHUDEnabled) {
                    SettingsToggleLabel(
                        symbol: "capsule.fill",
                        color: .blue,
                        title: "Show Camera HUD",
                        subtitle: "Show the in-camera information capsule."
                    )
                }
            }

            Section("MAIN INFO") {
                HapticFreeSettingsToggle(isOn: $hudResolution) { Text("Resolution") }
                if camera.captureMode != .photo {
                    HapticFreeSettingsToggle(isOn: $hudFPS) { Text("FPS") }
                }
                HapticFreeSettingsToggle(isOn: $hudRemaining) {
                    Text(camera.captureMode == .photo ? "Photos Remaining" : "Time Remaining")
                }
                HapticFreeSettingsToggle(isOn: $hudWhiteBalance) { Text("White Balance") }
                HapticFreeSettingsToggle(isOn: $hudLens) { Text("Active Lens") }
            }
            .disabled(!isHUDEnabled)

            Section("DEVICE INFO") {
                HapticFreeSettingsToggle(isOn: $hudBattery) { Text("Battery") }
                HapticFreeSettingsToggle(isOn: $hudStorage) { Text("Free Storage") }
                HapticFreeSettingsToggle(isOn: $hudThermal) { Text("Thermal Status") }
                if camera.captureMode != .photo {
                    HapticFreeSettingsToggle(isOn: $hudDroppedFrames) { Text("Frame Gaps") }
                }
            }
            .disabled(!isHUDEnabled)

            Section {
                Picker("Audio Level Meter", selection: $audioLevelMeter) {
                    ForEach(AudioLevelMeterMode.allCases) { mode in
                        Text(mode.displayName).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: audioLevelMeter) { _, rawValue in
                    if let mode = AudioLevelMeterMode(rawValue: rawValue) {
                        camera.setAudioLevelMeterMode(mode)
                    }
                }
                HapticFreeSettingsToggle(isOn: $audioPeakHold) {
                    SettingsToggleLabel(
                        symbol: "arrow.up.forward",
                        color: .orange,
                        title: "Peak Hold",
                        subtitle: "Hold the loudest recent meter level briefly."
                    )
                }
                .disabled(audioLevelMeter == AudioLevelMeterMode.off.rawValue)
            } header: {
                Text("RECORDING HUD")
            } footer: {
                Text("The meter reads the authorized microphone data output and appears only while recording. Peak Hold marks the loudest recent level. Decibel readouts are digital dBFS, not SPL or dBA.")
            }
            .disabled(!isHUDEnabled)

            Section("APPEARANCE") {
                Picker("Text Size", selection: $hudTextSize) {
                    Text("Compact").tag(10.0)
                    Text("Large").tag(12.0)
                }
                .pickerStyle(.menu)
            }
            .disabled(!isHUDEnabled)
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Camera HUD")
        .navigationBarTitleDisplayMode(.large)
        .tint(.blue)
    }
}
