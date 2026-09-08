import SwiftUI

struct ViewfinderHUDSettingsView: View {
    @Environment(\.cameraTint) private var theme
    @ObservedObject var camera: CameraManager
    @AppStorage("hapticCaptureEnabled") private var isHapticCaptureEnabled = true
    @AppStorage("keepScreenAwakeEnabled") private var keepScreenAwakeEnabled = false
    @AppStorage("cameraHUDEnabled") private var isHUDEnabled = true
    @AppStorage("cameraHUDResolution") private var hudResolution = true
    @AppStorage("cameraHUDFPS") private var hudFPS = true
    @AppStorage("cameraHUDRemaining") private var hudRemaining = true
    @AppStorage("cameraHUDWhiteBalance") private var hudWhiteBalance = false
    @AppStorage("cameraHUDBattery") private var hudBattery = false
    @AppStorage("cameraHUDStorage") private var hudStorage = false
    @AppStorage("cameraHUDDroppedFrames") private var hudDroppedFrames = false
    @AppStorage("thermalHUD") private var hudThermal = false
    @AppStorage("hudTextSize") private var hudTextSize = 10.0
    @AppStorage("appColorScheme") private var appColorScheme = "system"

    var body: some View {
        SettingsPage {
            SettingsCard(title: "Camera Experience", symbol: "sparkles") {
                SettingsToggleRow(
                    title: "Haptic Capture",
                    subtitle: camera.captureMode == .photo ? "Feel a tap when taking a photo" : "Feel a tap when starting or stopping recording",
                    symbol: "hand.tap.fill",
                    isOn: $isHapticCaptureEnabled
                )
                SettingsDivider()
                SettingsToggleRow(
                    title: "Keep Screen Awake",
                    subtitle: "Prevent Auto-Lock while LowPolyCam is open",
                    symbol: "sun.max.fill",
                    isOn: $keepScreenAwakeEnabled
                )
            }

            SettingsCard(title: "Camera HUD", symbol: "capsule.fill") {
                SettingsToggleRow(
                    title: "Show Camera HUD",
                    subtitle: "Compact live info between Flash and Settings",
                    symbol: "capsule.fill",
                    isOn: $isHUDEnabled
                )
            }

            if isHUDEnabled {
                SettingsCard(title: "HUD Information", symbol: "text.line.first.and.arrowtriangle.forward") {
                    SettingsToggleRow(title: "Battery", subtitle: "Show the current battery percentage", isOn: $hudBattery)
                    SettingsDivider()
                    SettingsToggleRow(title: "Free Storage", subtitle: "Show available space on this iPhone", isOn: $hudStorage)
                    SettingsDivider()
                    SettingsToggleRow(title: "Thermal Status", subtitle: "Show the current device thermal state", isOn: $hudThermal)
                    if camera.captureMode != .photo {
                        SettingsDivider()
                        SettingsToggleRow(title: "Frame Gaps", subtitle: "Check the last saved clip for missing frame intervals; not a live counter", isOn: $hudDroppedFrames)
                    }
                    SettingsDivider()
                    SettingsToggleRow(
                        title: "Resolution",
                        subtitle: camera.captureMode == .photo ? "Show selected photo resolution" : "Show selected video resolution",
                        isOn: $hudResolution
                    )

                    if camera.captureMode != .photo {
                        SettingsDivider()
                        SettingsToggleRow(
                            title: "FPS",
                            subtitle: camera.captureMode == .sloMo ? "Show selected Slo-Mo frame rate" : "Show selected video frame rate",
                            isOn: $hudFPS
                        )
                    }

                    SettingsDivider()

                    SettingsToggleRow(
                        title: camera.captureMode == .photo ? "Photos Remaining" : "Recording Time Remaining",
                        subtitle: camera.captureMode == .photo ? "Estimate how many more photos fit on the device" : "Estimate recording time from available storage and current quality",
                        isOn: $hudRemaining
                    )

                    SettingsDivider()

                    SettingsToggleRow(
                        title: "White Balance",
                        subtitle: "Show the active white-balance preset",
                        isOn: $hudWhiteBalance
                    )
                }

                SettingsCard(title: "HUD Appearance", symbol: "textformat.size") {
                    ThemeMenu(title: "Text Size", selection: $hudTextSize, options: [(10.0, "Compact"), (12.0, "Large")])
                }
            }
        }
        .tint(theme)
        .accentColor(theme)
        .preferredColorScheme(resolvedColorScheme(appColorScheme))
        .navigationTitle("Viewfinder & HUD")
        .navigationBarTitleDisplayMode(.inline)
    }
}
