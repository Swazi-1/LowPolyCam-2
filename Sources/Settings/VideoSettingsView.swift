import SwiftUI

/// Main settings hub. Search uses a flat index of individual settings so users can jump to the
/// page that owns a setting instead of only matching top-level menu names.
struct VideoSettingsView: View {
    @ObservedObject var camera: CameraManager
    var positionStats: () -> Void = {}

    @AppStorage("appColorScheme") private var appColorScheme = "system"
    @AppStorage("diagnosticLoggingEnabled") private var diagnosticsEnabled = false
    @State private var searchText = ""
    @State private var showingCameraSetup = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if isSearching {
                    searchContent
                } else {
                    settingsHome
                }
            }
            .listStyle(.insetGrouped)
            .listSectionSpacing(18)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search Settings")
            .navigationDestination(isPresented: $showingCameraSetup) {
                CameraSetupSettingsView(camera: camera)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            .tint(.blue)
            .accentColor(.blue)
            .preferredColorScheme(resolvedColorScheme(appColorScheme))
        }
    }

    @ViewBuilder
    private var settingsHome: some View {
        Section {
            Button {
                showingCameraSetup = true
            } label: {
                SettingsHeroButton(
                    title: "Camera Setup",
                    line1: "\(modeName) • \(camera.cameraPosition == .back ? "Rear" : "Front")",
                    line2: cameraSetupSummary
                )
            }
            .buttonStyle(.plain)
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }

        Section {
            NavigationLink {
                AppearanceSettingsView()
            } label: {
                SettingsNavigationLabel(
                    symbol: "sun.max.fill",
                    color: .gray,
                    title: "Appearance",
                    value: appearanceName
                )
            }
        }

        Section("CAPTURE") {
            NavigationLink {
                RecordVideoSettingsView(camera: camera)
            } label: {
                SettingsNavigationLabel(
                    symbol: "video.fill",
                    color: .red,
                    title: "Record Video",
                    value: videoSummary
                )
            }

            NavigationLink {
                SlowMotionSettingsView(camera: camera)
            } label: {
                SettingsNavigationLabel(
                    symbol: "slowmo",
                    color: .orange,
                    title: "Record Slo-Mo",
                    value: slowMotionSummary
                )
            }

            NavigationLink {
                PhotoCaptureSettingsView(camera: camera)
            } label: {
                SettingsNavigationLabel(
                    symbol: "camera.fill",
                    color: .green,
                    title: "Photo Capture",
                    value: "\(camera.currentPhotoResolutionLabel) · \(camera.photoFileFormat)"
                )
            }
        }

        Section("CONTROLS") {
            NavigationLink {
                QuickControlsSettingsView(camera: camera)
            } label: {
                SettingsNavigationLabel(
                    symbol: "slider.horizontal.3",
                    color: .gray,
                    title: "Quick Controls"
                )
            }

            NavigationLink {
                CapturePreferencesView(camera: camera)
            } label: {
                SettingsNavigationLabel(
                    symbol: "gearshape.fill",
                    color: .purple,
                    title: "Capture Preferences"
                )
            }

            NavigationLink {
                ViewfinderHUDSettingsView(camera: camera)
            } label: {
                SettingsNavigationLabel(
                    symbol: "rectangle.inset.filled",
                    color: .blue,
                    title: "Viewfinder & HUD"
                )
            }

            NavigationLink {
                AdvancedRecordingSettingsView(camera: camera, positionStats: positionStats)
            } label: {
                SettingsNavigationLabel(
                    symbol: "waveform.path.ecg",
                    color: .purple,
                    title: "Advanced Recording"
                )
            }

            NavigationLink {
                VideoPresetsView(camera: camera)
            } label: {
                SettingsNavigationLabel(
                    symbol: "star.fill",
                    color: .yellow,
                    title: "Video Presets"
                )
            }
        }

        Section("APP") {
            NavigationLink {
                DiagnosticsSettingsView()
            } label: {
                SettingsNavigationLabel(
                    symbol: "waveform.path.ecg",
                    color: .red,
                    title: "Diagnostics",
                    value: diagnosticsEnabled ? "On" : "Off"
                )
            }

            NavigationLink {
                AboutSettingsView()
            } label: {
                SettingsNavigationLabel(
                    symbol: "info.circle.fill",
                    color: .gray,
                    title: "About"
                )
            }
        }
    }

    @ViewBuilder
    private var searchContent: some View {
        if filteredSearchEntries.isEmpty {
            Section {
                ContentUnavailableView.search(text: searchText)
            }
        } else {
            Section("RESULTS") {
                ForEach(filteredSearchEntries) { entry in
                    NavigationLink {
                        destinationView(for: entry.destination)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.title)
                                .foregroundStyle(.primary)
                            Text(entry.path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func destinationView(for destination: SettingsSearchDestination) -> some View {
        switch destination {
        case .cameraSetup:
            CameraSetupSettingsView(camera: camera)
        case .appearance:
            AppearanceSettingsView()
        case .recordVideo:
            RecordVideoSettingsView(camera: camera)
        case .codecCompression:
            CodecCompressionSettingsView(camera: camera)
        case .slowMotion:
            SlowMotionSettingsView(camera: camera)
        case .photoCapture:
            PhotoCaptureSettingsView(camera: camera)
        case .quickControls:
            QuickControlsSettingsView(camera: camera)
        case .shutterHaptics:
            ShutterHapticsSettingsView()
        case .zoomRecording:
            ZoomRecordingSettingsView(camera: camera)
        case .cameraControls:
            CameraControlsSettingsView(camera: camera)
        case .viewfinderHUD:
            ViewfinderHUDSettingsView(camera: camera)
        case .advancedRecording:
            AdvancedRecordingSettingsView(camera: camera, positionStats: positionStats)
        case .liveStats:
            LiveStatsSettings(positionStats: positionStats)
        case .videoPresets:
            VideoPresetsView(camera: camera)
        case .diagnostics:
            DiagnosticsSettingsView()
        case .about:
            AboutSettingsView()
        }
    }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var filteredSearchEntries: [SettingsSearchEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        return Self.searchEntries.filter { entry in
            entry.searchText.localizedCaseInsensitiveContains(query)
        }
    }

    private static let searchEntries: [SettingsSearchEntry] = [
        .init("Camera Setup", "Settings › Camera Setup", "capture mode video photo slo-mo rear front camera", .cameraSetup),
        .init("Capture Mode", "Settings › Camera Setup", "video photo slo-mo mode", .cameraSetup),
        .init("Rear / Front Camera", "Settings › Camera Setup", "switch camera selfie rear front", .cameraSetup),

        .init("App Appearance", "Settings › Appearance", "system light dark theme", .appearance),
        .init("Camera Accent", "Settings › Appearance", "ice sunset mint lavender coral custom color preview", .appearance),
        .init("Custom Accent", "Settings › Appearance", "custom color camera accent", .appearance),

        .init("Video Resolution", "Settings › Record Video", "4k 1080p 720p quality", .recordVideo),
        .init("Video Frame Rate", "Settings › Record Video", "24 30 60 fps frame rate", .recordVideo),
        .init("Stabilization", "Settings › Record Video", "video stabilization shake", .recordVideo),
        .init("Codec", "Settings › Record Video › Codec & Compression", "hevc h264 h.264 codec", .codecCompression),
        .init("Compression", "Settings › Record Video › Codec & Compression", "data saver medium high compression bitrate quality", .codecCompression),
        .init("HEVC", "Settings › Record Video › Codec & Compression", "codec h265", .codecCompression),
        .init("H.264", "Settings › Record Video › Codec & Compression", "h264 codec avc", .codecCompression),
        .init("Data Saver", "Settings › Record Video › Codec & Compression", "compression small files", .codecCompression),
        .init("Medium Compression", "Settings › Record Video › Codec & Compression", "balanced compression", .codecCompression),
        .init("High Compression Quality", "Settings › Record Video › Codec & Compression", "high quality compression", .codecCompression),

        .init("Slo-Mo Resolution", "Settings › Record Slo-Mo", "slow motion 1080p 720p", .slowMotion),
        .init("Slo-Mo Frame Rate", "Settings › Record Slo-Mo", "slow motion 120 240 fps", .slowMotion),

        .init("Megapixels", "Settings › Photo Capture", "mp photo resolution quality 12 8 4", .photoCapture),
        .init("Photos per Burst", "Settings › Photo Capture", "burst count 5 10 15", .photoCapture),
        .init("Photo Format", "Settings › Photo Capture", "heic jpeg format", .photoCapture),
        .init("HEIC", "Settings › Photo Capture", "photo format", .photoCapture),
        .init("JPEG", "Settings › Photo Capture", "photo format", .photoCapture),
        .init("Aspect Ratio", "Settings › Photo Capture", "4:3 1:1 square aspect", .photoCapture),
        .init("Photo Flash", "Settings › Photo Capture", "flash auto on off", .photoCapture),

        .init("Grid", "Settings › Quick Controls", "composition guides grid", .quickControls),
        .init("Grid Opacity", "Settings › Quick Controls", "grid transparency opacity", .quickControls),
        .init("Level", "Settings › Quick Controls", "horizon level meter gyroscope", .quickControls),
        .init("Center Crosshair", "Settings › Quick Controls", "center marker crosshair", .quickControls),

        .init("Timer", "Settings › Capture Preferences › Shutter & Haptics", "shutter delay 3 10 seconds", .shutterHaptics),
        .init("Haptic Capture", "Settings › Capture Preferences › Shutter & Haptics", "haptic feedback shutter", .shutterHaptics),
        .init("Countdown Haptics", "Settings › Capture Preferences › Shutter & Haptics", "timer haptic feedback", .shutterHaptics),
        .init("Haptic Strength", "Settings › Capture Preferences › Shutter & Haptics", "low medium strong strength", .shutterHaptics),

        .init("Zoom Speed", "Settings › Capture Preferences › Zoom & Recording", "slow normal fast zoom", .zoomRecording),
        .init("Tap Zoom to Reset", "Settings › Capture Preferences › Zoom & Recording", "zoom reset", .zoomRecording),
        .init("Lock Recording Controls", "Settings › Capture Preferences › Zoom & Recording", "recording lock controls", .zoomRecording),
        .init("Low Storage Warning", "Settings › Capture Preferences › Zoom & Recording", "storage warning 1 gb", .zoomRecording),

        .init("Remember Camera Mode", "Settings › Capture Preferences › Camera Controls", "remember capture mode", .cameraControls),
        .init("Mirror Saved Selfies", "Settings › Capture Preferences › Camera Controls", "selfie mirror front camera", .cameraControls),
        .init("Reset Exposure & White Balance", "Settings › Capture Preferences › Camera Controls", "reset ev wb white balance exposure", .cameraControls),

        .init("Viewfinder & HUD", "Settings › Viewfinder & HUD", "hud display viewfinder", .viewfinderHUD),
        .init("Keep Screen Awake", "Settings › Viewfinder & HUD", "auto lock screen awake", .viewfinderHUD),
        .init("Show Camera HUD", "Settings › Viewfinder & HUD", "camera hud capsule display", .viewfinderHUD),
        .init("HUD Resolution", "Settings › Viewfinder & HUD", "resolution hud content", .viewfinderHUD),
        .init("HUD FPS", "Settings › Viewfinder & HUD", "fps frame rate hud content", .viewfinderHUD),
        .init("Photos / Time Remaining", "Settings › Viewfinder & HUD", "photos remaining time remaining hud", .viewfinderHUD),
        .init("HUD White Balance", "Settings › Viewfinder & HUD", "white balance wb hud", .viewfinderHUD),
        .init("Battery HUD", "Settings › Viewfinder & HUD", "battery hud display", .viewfinderHUD),
        .init("Free Storage HUD", "Settings › Viewfinder & HUD", "storage remaining free storage hud", .viewfinderHUD),
        .init("Thermal Status HUD", "Settings › Viewfinder & HUD", "temperature thermal status hud", .viewfinderHUD),
        .init("Frame Gaps HUD", "Settings › Viewfinder & HUD", "frame gaps dropped frames hud", .viewfinderHUD),
        .init("HUD Text Size", "Settings › Viewfinder & HUD", "compact large text size hud", .viewfinderHUD),

        .init("Live Recording Stats", "Settings › Advanced Recording", "live stats fps bitrate drops", .advancedRecording),
        .init("Live Stats Settings", "Settings › Advanced Recording › Live Stats", "panel size position fps bitrate drops", .liveStats),
        .init("Live Stats Panel Size", "Settings › Advanced Recording › Live Stats", "compact normal panel size", .liveStats),
        .init("Capture FPS Stat", "Settings › Advanced Recording › Live Stats", "capture fps live stats", .liveStats),
        .init("File Bitrate Stat", "Settings › Advanced Recording › Live Stats", "file bitrate mbps live stats", .liveStats),
        .init("Capture Drops Stat", "Settings › Advanced Recording › Live Stats", "drops frame gaps live stats", .liveStats),
        .init("Position Live Stats", "Settings › Advanced Recording › Live Stats", "drag position panel live stats", .liveStats),
        .init("Split Recording", "Settings › Advanced Recording", "15 30 60 120 minutes split clips", .advancedRecording),
        .init("Longevity Mode", "Settings › Advanced Recording", "long recording battery 720p data saver", .advancedRecording),
        .init("Recording Recovery", "Settings › Advanced Recording", "recover retry recording", .advancedRecording),
        .init("Low-Storage Protection", "Settings › Advanced Recording", "critical storage protection safety", .advancedRecording),
        .init("Background Save Protection", "Settings › Advanced Recording", "background save protection safety", .advancedRecording),

        .init("Balanced Preset", "Settings › Video Presets", "balanced preset", .videoPresets),
        .init("High Quality Preset", "Settings › Video Presets", "high quality preset", .videoPresets),
        .init("All Rounder Preset", "Settings › Video Presets", "all rounder preset", .videoPresets),
        .init("All Day Preset", "Settings › Video Presets", "all day preset battery", .videoPresets),
        .init("Social Preset", "Settings › Video Presets", "social preset", .videoPresets),

        .init("Diagnostics", "Settings › Diagnostics", "logs logging bug report diagnostics", .diagnostics),
        .init("Save Diagnostic Logs", "Settings › Diagnostics", "logging logs bug report", .diagnostics),
        .init("About LowPolyCam", "Settings › About", "version build app about", .about)
    ]

    private var appearanceName: String {
        switch appColorScheme {
        case "light": return "Light"
        case "dark": return "Dark"
        default: return "System"
        }
    }

    private var codecName: String {
        camera.selectedVideoCodec == "HEVC" ? "HEVC" : "H.264"
    }

    private var modeName: String {
        switch camera.captureMode {
        case .video: return "Video"
        case .photo: return "Photo"
        case .sloMo: return "Slo-Mo"
        }
    }

    private var cameraSetupSummary: String {
        switch camera.captureMode {
        case .video:
            return "\(camera.selectedResolution.rawValue) · \(camera.selectedFrameRate.rawValue) fps · \(codecName)"
        case .sloMo:
            return "\(camera.selectedSlowMotionResolution.rawValue) · \(camera.selectedSlowMotionFrameRate.rawValue) fps · HEVC"
        case .photo:
            return "\(camera.currentPhotoResolutionLabel) · \(camera.photoFileFormat)"
        }
    }

    private var videoSummary: String {
        "\(camera.selectedResolution.rawValue) · \(camera.selectedFrameRate.rawValue) fps"
    }

    private var slowMotionSummary: String {
        "\(camera.selectedSlowMotionResolution.rawValue) · \(camera.selectedSlowMotionFrameRate.rawValue) fps"
    }
}

private enum SettingsSearchDestination: Hashable {
    case cameraSetup
    case appearance
    case recordVideo
    case codecCompression
    case slowMotion
    case photoCapture
    case quickControls
    case shutterHaptics
    case zoomRecording
    case cameraControls
    case viewfinderHUD
    case advancedRecording
    case liveStats
    case videoPresets
    case diagnostics
    case about
}

private struct SettingsSearchEntry: Identifiable {
    let id: String
    let title: String
    let path: String
    let keywords: String
    let destination: SettingsSearchDestination

    init(_ title: String, _ path: String, _ keywords: String, _ destination: SettingsSearchDestination) {
        self.id = "\(path)|\(title)"
        self.title = title
        self.path = path
        self.keywords = keywords
        self.destination = destination
    }

    var searchText: String {
        "\(title) \(path) \(keywords)"
    }
}
