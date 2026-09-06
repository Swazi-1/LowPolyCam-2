import SwiftUI

struct CapturePreferencesView: View {
    @ObservedObject var camera: CameraManager
    init(camera: CameraManager) { self.camera = camera }
    @AppStorage("shutterDelay") private var shutterDelay = 0
    @AppStorage("splitMinutes") private var splitMinutes = 0
    @AppStorage("hapticCaptureEnabled") private var haptics = true
    @AppStorage("hapticStrength") private var strength = "Medium"
    @AppStorage("centerCrosshair") private var crosshair = false
    @AppStorage("mirrorSelfies") private var mirrorSelfies = false
    private var accent = CameraAccent()
    @AppStorage("zoomSpeed") private var zoomSpeed = 1.0
    @AppStorage("tapZoomReset") private var tapZoomReset = true
    @AppStorage("recordingLock") private var recordingLock = false
    @AppStorage("lowStorageWarning") private var lowStorageWarning = true
    @AppStorage("countdownHaptics") private var countdownHaptics = false
    @AppStorage("rememberCaptureMode") private var rememberCaptureMode = false

    var body: some View {
        SettingsPage {
            if camera.captureMode != .photo {
                SettingsCard(title: "Recording Timer", symbol: "timer") {
                    ThemeMenu(title: "Timer", selection: $shutterDelay, options: [(0, "Off"), (3, "3 seconds"), (5, "5 seconds"), (10, "10 seconds")])
                }
            }
            if camera.captureMode != .photo {
                SettingsCard(title: "Recording", symbol: "video.fill") {
                    ThemeMenu(title: "Video Codec", selection: $camera.selectedVideoCodec, options: [("HEVC", "HEVC / H.265"), ("H264", "H.264")])
                    if let message = camera.codecAvailabilityMessage {
                        Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    ThemeMenu(title: "Compression", selection: $camera.videoCompression, options: VideoCompression.allCases.map { ($0, $0.rawValue) })
                    Text("High uses the native encoder defaults. Medium and Data Saver reduce the bitrate to save space.").font(.caption).foregroundStyle(.secondary)
                    ThemeMenu(title: "Split Recording", selection: $splitMinutes, options: [(0, "Off"), (15, "Every 15 minutes"), (30, "Every 30 minutes"), (60, "Every hour"), (120, "Every 2 hours")])
                    Text("Split clips save separately with a brief gap between files. Codec availability depends on the selected camera format.").font(.caption).foregroundStyle(.secondary)
                }
            }
            SettingsCard(title: "Capture Haptics", symbol: "waveform") {
                Toggle("Enabled", isOn: $haptics)
                ThemeMenu(title: "Strength", selection: $strength, options: ["Low", "Medium", "Strong"].map { ($0, $0) }, onSelect: { CameraHaptics.fire(strength: $0) }).disabled(!haptics)
            }
            SettingsCard(title: "Zoom & Recording", symbol: "plus.magnifyingglass") {
                ThemeMenu(title: "Zoom Speed", selection: $zoomSpeed, options: [(0.5, "Slow"), (1.0, "Normal"), (1.5, "Fast")])
                Toggle("Tap Zoom to Reset to 1×", isOn: $tapZoomReset)
                if camera.captureMode != .photo {
                    Toggle("Lock Recording Controls", isOn: $recordingLock)
                    Text("When locked, hold the shutter for one second to stop.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Low Storage Warning", isOn: $lowStorageWarning)
            }
            SettingsCard(title: "More Controls", symbol: "slider.horizontal.3") {
                Toggle("Countdown Haptics", isOn: $countdownHaptics)
                Toggle("Remember Last Camera Mode", isOn: $rememberCaptureMode)
                Button("Reset Exposure & White Balance") { camera.setExposureBias(0); camera.selectWhiteBalancePreset(.auto) }
                Toggle("Center Crosshair", isOn: $crosshair)
                Toggle("Mirror Saved Selfies", isOn: $mirrorSelfies)
            }
        }
        .tint(accent.color)
        .accentColor(accent.color)
        .navigationTitle("Capture Controls")
        .navigationBarTitleDisplayMode(.inline)
    }
}
