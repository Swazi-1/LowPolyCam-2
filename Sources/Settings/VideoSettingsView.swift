import SwiftUI
import Foundation

/// Main settings hub. Search uses a flat index of individual settings so users can jump to the
/// page that owns a setting instead of only matching top-level menu names.
struct VideoSettingsView: View {
    @ObservedObject var camera: CameraManager
    var positionStats: () -> Void = {}

    @AppStorage("appColorScheme") private var appColorScheme = "dark"
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
                    title: "Preferences"
                )
            }

            NavigationLink {
                CameraHUDSettingsView(camera: camera)
            } label: {
                SettingsNavigationLabel(
                    symbol: "rectangle.inset.filled",
                    color: .blue,
                    title: "Camera HUD"
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
                        HStack(spacing: 12) {
                            SettingsListIcon(symbol: entry.symbol, color: entry.color)

                            VStack(alignment: .leading, spacing: 3) {
                                Text(entry.title)
                                    .foregroundStyle(.primary)
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(entry.path)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                            }

                            Spacer(minLength: 4)
                        }
                        .padding(.vertical, 2)
                        .contentShape(Rectangle())
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
        case .preferences:
            CapturePreferencesView(camera: camera)
        case .zoomControls:
            ZoomControlsSettingsView(camera: camera)
        case .cameraHUD:
            CameraHUDSettingsView(camera: camera)
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
        return Self.searchEntries
            .filter { $0.matches(query) && isSearchEntryAvailable($0) }
            .sorted {
                let left = $0.score(for: query)
                let right = $1.score(for: query)
                if left == right { return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
                return left > right
            }
    }

    private func isSearchEntryAvailable(_ entry: SettingsSearchEntry) -> Bool {
        switch entry.destination {
        case .recordVideo:
            guard camera.capabilitySnapshot.isReady else { return true }
            let title = entry.title.lowercased()
            let resolution: VideoResolution? = title.contains("4k")
                ? .p4k
                : title.contains("1080") ? .p1080
                : title.contains("720") ? .p720
                : nil
            let frameRate: VideoFrameRate? = title.contains("60 fps")
                ? .fps60
                : title.contains("30 fps") ? .fps30
                : title.contains("24 fps") ? .fps24
                : nil
            if let resolution, let frameRate {
                return camera.capabilitySnapshot.videoPairs.contains {
                    $0.resolution == resolution && $0.frameRate == frameRate
                }
            }
            return !camera.capabilitySnapshot.videoPairs.isEmpty
        case .codecCompression:
            guard camera.capabilitySnapshot.isReady else { return true }
            if entry.title == "H.264" {
                return camera.capabilitySnapshot.availableVideoCodecs.contains("H264")
            }
            if entry.title == "HEVC" {
                return camera.capabilitySnapshot.availableVideoCodecs.contains("HEVC")
            }
            return !camera.capabilitySnapshot.availableVideoCodecs.isEmpty
        case .slowMotion:
            guard camera.capabilitySnapshot.isReady else { return true }
            let title = entry.title.lowercased()
            let resolution: VideoResolution? = title.contains("1080") ? .p1080 : title.contains("720") ? .p720 : nil
            let frameRate: CameraManager.SlowMotionFrameRate? = title.contains("240 fps")
                ? .fps240
                : title.contains("120 fps") ? .fps120
                : nil
            if let resolution, let frameRate {
                return camera.capabilitySnapshot.slowMotionPairs.contains {
                    $0.resolution == resolution && $0.frameRate == frameRate
                }
            }
            return !camera.capabilitySnapshot.slowMotionPairs.isEmpty
        case .liveStats:
            return camera.captureMode != .photo
        default:
            return true
        }
    }

    static let searchEntries: [SettingsSearchEntry] = {
        var entries: [SettingsSearchEntry] = [
            .init("Camera Setup", "Settings › Camera Setup", "capture mode remember setup screen awake", "video.fill", .blue, .cameraSetup),
            .init("Capture Mode", "Settings › Camera Setup", "video photo slo mo slow motion mode", "video.fill", .blue, .cameraSetup),
            .init("Remember Camera Setup", "Settings › Camera Setup", "remember restore startup launch last capture mode camera setup", "arrow.counterclockwise.circle.fill", .green, .cameraSetup),
            .init("Keep Screen Awake", "Settings › Camera Setup", "keep screen awake auto lock display", "sun.max.fill", .orange, .cameraSetup),
            .init("Capture Orientation", "Settings › Camera Setup", "orientation auto portrait landscape left right rotation mirror photo video slo mo", "rectangle.portrait.rotate", .blue, .cameraSetup),
            .init("Zoom Controls", "Settings › Camera Setup › Zoom Controls", "zoom buttons shortcuts master off on 0.5 1 2 4 5 custom", "plus.magnifyingglass", .purple, .zoomControls),
            .init("Custom Zoom Buttons", "Settings › Camera Setup › Zoom Controls", "custom zoom shortcut buttons 3 4 5 button values lens ramp enable disable", "plus.magnifyingglass", .purple, .zoomControls),
            .init("Zoom Button Count", "Settings › Camera Setup › Zoom Controls", "number of buttons 3 4 5 shortcuts", "plus.magnifyingglass", .purple, .zoomControls),

            .init("Appearance", "Settings › Appearance", "app appearance system light dark theme", "sun.max.fill", .gray, .appearance),
            .init("Camera Accent", "Settings › Appearance", "accent color ice sunset mint lavender coral custom preview", "sun.max.fill", .purple, .appearance),
            .init("Custom Accent", "Settings › Appearance", "custom camera accent color picker rgb", "sun.max.fill", .purple, .appearance),

            .init("Record Video", "Settings › Record Video", "video quality resolution frame rate fps", "video.fill", .red, .recordVideo),
            .init("Video Resolution", "Settings › Record Video", "4k 2160p 1080p 720p quality", "video.fill", .red, .recordVideo),
            .init("Video Frame Rate", "Settings › Record Video", "24 30 60 fps frame rate", "video.fill", .red, .recordVideo),
            .init("Codec & Compression", "Settings › Record Video › Codec & Compression", "codec compression hevc h264 h265 bitrate", "internaldrive.fill", .blue, .codecCompression),
            .init("Video Compression", "Settings › Record Video › Codec & Compression", "video compression auto manual high medium data saver quality bitrate", "internaldrive.fill", .blue, .codecCompression),
            .init("Compression", "Settings › Record Video › Codec & Compression", "video compression auto manual high medium data saver bitrate", "internaldrive.fill", .blue, .codecCompression),
            .init("Compression Level", "Settings › Record Video › Codec & Compression", "video compression level high medium data saver quality", "internaldrive.fill", .blue, .codecCompression),
            .init("Manual Bitrate", "Settings › Record Video › Codec & Compression", "manual bitrate direct input mbps 1 50 200 requested effective recommendation", "internaldrive.fill", .blue, .codecCompression),
            .init("Bitrate", "Settings › Record Video › Codec & Compression", "manual bitrate mbps 1 200 video compression", "internaldrive.fill", .blue, .codecCompression),
            .init("HEVC", "Settings › Record Video › Codec & Compression", "hevc h265 h 265 codec", "internaldrive.fill", .blue, .codecCompression),
            .init("H.264", "Settings › Record Video › Codec & Compression", "h264 h 264 avc codec", "internaldrive.fill", .blue, .codecCompression),
            .init("Data Saver", "Settings › Record Video › Codec & Compression", "compression smallest files low bitrate", "internaldrive.fill", .blue, .codecCompression),
            .init("Medium Compression", "Settings › Record Video › Codec & Compression", "medium balanced compression bitrate", "internaldrive.fill", .blue, .codecCompression),
            .init("High Compression Quality", "Settings › Record Video › Codec & Compression", "high compression highest recording quality bitrate", "internaldrive.fill", .blue, .codecCompression),
            .init("Stabilization", "Settings › Record Video", "video stabilization camera shake", "dot.radiowaves.left.and.right", .green, .recordVideo),

            .init("Record Slo-Mo", "Settings › Record Slo-Mo", "slow motion slo mo slowmo quality fps", "slowmo", .orange, .slowMotion),
            .init("Slo-Mo Resolution", "Settings › Record Slo-Mo", "1080p 720p slow motion resolution", "slowmo", .orange, .slowMotion),
            .init("Slo-Mo Frame Rate", "Settings › Record Slo-Mo", "120 240 fps slow motion frame rate", "slowmo", .orange, .slowMotion),
            .init("Slo-Mo Compression", "Settings › Record Slo-Mo", "slow motion compression auto manual high medium data saver bitrate", "slowmo", .orange, .slowMotion),
            .init("Slo-Mo Compression Level", "Settings › Record Slo-Mo", "slow motion compression level high medium data saver quality", "slowmo", .orange, .slowMotion),
            .init("Slo-Mo Manual Bitrate", "Settings › Record Slo-Mo", "slow motion manual bitrate direct input mbps 1 50 200 requested effective recommendation", "slowmo", .orange, .slowMotion),
            .init("Slo-Mo Bitrate", "Settings › Record Slo-Mo", "slow motion manual bitrate mbps", "slowmo", .orange, .slowMotion),

            .init("Photo Capture", "Settings › Photo Capture", "photo camera megapixels format aspect extras", "camera.fill", .green, .photoCapture),
            .init("Megapixels", "Settings › Photo Capture", "mp photo resolution quality megapixel", "camera.fill", .green, .photoCapture),
            .init("Photo Format", "Settings › Photo Capture", "heic jpeg jpg photo format", "camera.fill", .green, .photoCapture),
            .init("HEIC", "Settings › Photo Capture", "heic photo format", "camera.fill", .green, .photoCapture),
            .init("JPEG", "Settings › Photo Capture", "jpeg jpg photo format", "camera.fill", .green, .photoCapture),
            .init("Aspect Ratio", "Settings › Photo Capture", "4 3 1 1 square aspect ratio", "camera.fill", .green, .photoCapture),
            .init("Photos per Burst", "Settings › Photo Capture", "burst photos count 15 10 5", "camera.fill", .green, .photoCapture),
            .init("Photo Flash", "Settings › Photo Capture", "flash auto on off still photo", "camera.fill", .green, .photoCapture),

            .init("Quick Controls", "Settings › Quick Controls", "camera composition controls", "slider.horizontal.3", .gray, .quickControls),
            .init("Grid", "Settings › Quick Controls", "composition grid guides", "grid", .blue, .quickControls),
            .init("Grid Opacity", "Settings › Quick Controls", "grid opacity transparency percent", "grid", .blue, .quickControls),
            .init("Grid Style", "Settings › Quick Controls", "rule of thirds square diagonal golden ratio composition", "grid", .blue, .quickControls),
            .init("Level", "Settings › Quick Controls", "horizon level meter gyroscope", "gyroscope", .orange, .quickControls),
            .init("Center Crosshair", "Settings › Quick Controls", "center marker crosshair", "plus", .gray, .quickControls),

            .init("Preferences", "Settings › Preferences", "capture preferences shutter timer zoom recording haptics camera controls", "gearshape.fill", .purple, .preferences),
            .init("Timer", "Settings › Preferences", "timer shutter delay off 3 seconds 10 seconds", "timer", .orange, .preferences),
            .init("Zoom Speed", "Settings › Preferences", "zoom speed slow normal fast", "plus.magnifyingglass", .blue, .preferences),
            .init("Tap Zoom to Reset", "Settings › Preferences", "tap zoom reset", "plus.magnifyingglass", .blue, .preferences),
            .init("AE/AF Lock Mode", "Settings › Preferences", "focus exposure ae af lock mode ae only af only long press", "viewfinder", .yellow, .preferences),
            .init("Tap Focus Reset", "Settings › Preferences", "tap focus reset auto focus exposure continuous 1 3 5 seconds never", "scope", .orange, .preferences),
            .init("Lock Recording Controls", "Settings › Preferences", "lock recording controls safeguard", "lock.fill", .blue, .preferences),
            .init("Low Storage Warning", "Settings › Preferences", "low storage warning 1 gb", "externaldrive.fill.badge.checkmark", .blue, .preferences),
            .init("Haptics", "Settings › Preferences", "app haptics haptic feedback vibration buttons controls shutter capture countdown", "waveform.path.ecg", .orange, .preferences),
            .init("Haptic Strength", "Settings › Preferences", "haptic low medium strong feedback strength", "waveform.path.ecg", .orange, .preferences),
            .init("Countdown Haptics", "Settings › Preferences", "timer countdown haptic feedback vibration", "timer", .orange, .preferences),
            .init("Mirror Saved Selfies", "Settings › Preferences", "mirror saved selfie front camera", "camera.metering.center.weighted", .gray, .preferences),
            .init("Reset Exposure & White Balance", "Settings › Preferences", "reset exposure ev white balance wb auto", "arrow.counterclockwise", .gray, .preferences),
            .init("Torch Brightness", "Settings › Preferences › Camera", "torch flashlight brightness long press level normalized remembered lens handoff", "bolt.fill", .orange, .preferences),
            .init("White Balance Preset", "Settings › Preferences › White Balance", "white balance auto daylight cloudy tungsten fluorescent custom temperature tint kelvin", "thermometer.sun.fill", .orange, .preferences),
            .init("Custom White Balance", "Settings › Preferences › White Balance", "custom wb temperature 2500 10000 kelvin tint gains reset default", "thermometer.sun.fill", .orange, .preferences),
            .init("Reset Temporary Camera Controls", "Settings › Preferences › Camera", "reset temporary exposure zoom white balance focus", "arrow.counterclockwise", .gray, .preferences),

            .init("Camera HUD", "Settings › Camera HUD", "hud display camera capsule", "rectangle.inset.filled", .blue, .cameraHUD),
            .init("Show Camera HUD", "Settings › Camera HUD", "show camera hud capsule", "rectangle.inset.filled", .blue, .cameraHUD),
            .init("HUD Resolution", "Settings › Camera HUD › Main Info", "resolution hud main info", "rectangle.inset.filled", .blue, .cameraHUD),
            .init("HUD FPS", "Settings › Camera HUD › Main Info", "fps frame rate hud", "rectangle.inset.filled", .blue, .cameraHUD),
            .init("Photos / Time Remaining", "Settings › Camera HUD › Main Info", "photos remaining time remaining hud", "rectangle.inset.filled", .blue, .cameraHUD),
            .init("HUD White Balance", "Settings › Camera HUD › Main Info", "white balance wb hud", "rectangle.inset.filled", .blue, .cameraHUD),
            .init("Battery HUD", "Settings › Camera HUD › Device Info", "battery device info hud", "battery.100percent", .green, .cameraHUD),
            .init("Free Storage HUD", "Settings › Camera HUD › Device Info", "free storage device info hud", "externaldrive.fill.badge.checkmark", .blue, .cameraHUD),
            .init("Thermal Status HUD", "Settings › Camera HUD › Device Info", "thermal temperature status hud", "waveform.path.ecg", .orange, .cameraHUD),
            .init("Frame Gaps HUD", "Settings › Camera HUD › Device Info", "frame gaps dropped frames hud", "waveform.path.ecg", .purple, .cameraHUD),
            .init("HUD Text Size", "Settings › Camera HUD › Appearance", "text size compact large hud", "text.line.first.and.arrowtriangle.forward", .purple, .cameraHUD),
            .init("Audio Level Meter", "Settings › Camera HUD › Recording HUD", "audio recording microphone level meter bars db dbfs decibels clipping recording only", "mic.fill", .green, .cameraHUD),
            .init("Clean Preview Gesture", "Settings › Quick Controls", "clean preview hide ui two finger tap double tap temporary", "rectangle.inset.filled", .blue, .quickControls),

            .init("Advanced Recording", "Settings › Advanced Recording", "recording advanced live stats split longevity safety", "waveform.path.ecg", .purple, .advancedRecording),
            .init("Live Recording Stats", "Settings › Advanced Recording", "live stats fps bitrate frame drops", "chart.bar.fill", .blue, .advancedRecording),
            .init("Live Stats Settings", "Settings › Advanced Recording › Live Stats", "panel size information position", "slider.horizontal.3", .gray, .liveStats),
            .init("Live Stats Panel Size", "Settings › Advanced Recording › Live Stats", "panel size compact normal", "chart.bar.fill", .blue, .liveStats),
            .init("Capture FPS Stat", "Settings › Advanced Recording › Live Stats", "capture fps live stat", "chart.bar.fill", .blue, .liveStats),
            .init("File Bitrate Stat", "Settings › Advanced Recording › Live Stats", "file bitrate mbps live stat", "chart.bar.fill", .blue, .liveStats),
            .init("Capture Drops Stat", "Settings › Advanced Recording › Live Stats", "capture drops frame gaps live stat", "chart.bar.fill", .blue, .liveStats),
            .init("Position Live Stats", "Settings › Advanced Recording › Live Stats", "drag position reset live stats", "chart.bar.fill", .blue, .liveStats),
            .init("Split Recording", "Settings › Advanced Recording", "split recording off 15 30 60 120 minutes hour 2 hours", "waveform.path.ecg", .purple, .advancedRecording),
            .init("Longevity Mode", "Settings › Advanced Recording", "longevity long recording battery 720p 30 fps hevc data saver dim", "battery.100percent", .green, .advancedRecording),
            .init("Recording Recovery", "Settings › Advanced Recording", "recovery retry failed photos import recordings", "arrow.counterclockwise.circle.fill", .purple, .advancedRecording),
            .init("Low-Storage Protection", "Settings › Advanced Recording", "critical low storage protection safely finalize clip", "externaldrive.fill.badge.checkmark", .blue, .advancedRecording),
            .init("Background Save Protection", "Settings › Advanced Recording", "background save protection pending photo video saves", "square.and.arrow.down.fill", .green, .advancedRecording),
            .init("Recording Start Countdown", "Settings › Advanced Recording", "recording countdown off 1 3 5 seconds video slo mo start cancel", "timer", .orange, .advancedRecording),
            .init("Zebra Exposure Warning", "Settings › Advanced Recording", "zebra exposure highlights clipping diagonal stripes preview only", "stripe.3.horizontal", .yellow, .advancedRecording),
            .init("Audio Recording", "Settings › Advanced Recording", "microphone audio recording mic permission status", "mic.fill", .green, .advancedRecording),

            .init("Video Presets", "Settings › Video Presets", "video presets balanced high quality all rounder all day social", "star.fill", .yellow, .videoPresets),
            .init("Balanced Preset", "Settings › Video Presets", "balanced 1080p medium 30 fps hevc", "slider.horizontal.3", .blue, .videoPresets),
            .init("High Quality Preset", "Settings › Video Presets", "high quality 4k 30 fps hevc high", "sparkles", .purple, .videoPresets),
            .init("All Rounder Preset", "Settings › Video Presets", "all rounder 1080p 60 fps hevc high", "square.grid.2x2.fill", .green, .videoPresets),
            .init("All Day Preset", "Settings › Video Presets", "all day 720p 30 fps hevc data saver battery", "battery.100percent", .orange, .videoPresets),
            .init("Social Preset", "Settings › Video Presets", "social 1080p 30 fps hevc data saver", "person.2.fill", .pink, .videoPresets),
            .init("Custom Presets", "Settings › Video Presets", "custom camera presets save apply rename delete setup", "slider.horizontal.3", .purple, .videoPresets),

            .init("Diagnostics", "Settings › Diagnostics", "diagnostics logs logging bug report", "waveform.path.ecg", .red, .diagnostics),
            .init("Save Diagnostic Logs", "Settings › Diagnostics", "save diagnostic logs logging bug report", "doc.text.fill", .red, .diagnostics),
            .init("Extreme Bug Trace", "Settings › Diagnostics", "extreme max diagnostics trace zoom lens request timing guard hardware readback", "waveform.path.ecg.rectangle.fill", .orange, .diagnostics),
            .init("Diagnostic Log Location", "Settings › Diagnostics", "files on my iphone lowpolycam logs location folder", "folder.fill", .blue, .diagnostics),
            .init("Numbered Sessions", "Settings › Diagnostics", "numbered sessions separate log each launch", "number", .gray, .diagnostics),
            .init("About LowPolyCam", "Settings › About", "about version build app", "info.circle.fill", .gray, .about)
        ]

        let videoResolutions: [(title: String, aliases: String)] = [
            ("4K", "4k 2160p uhd"),
            ("1080p HD", "1080p full hd fhd"),
            ("720p HD", "720p hd")
        ]
        for resolution in videoResolutions {
            for fps in [60, 30, 24] {
                let compactName = resolution.title.hasPrefix("4K") ? "4k\(fps)" : "\(resolution.title.components(separatedBy: " ").first ?? resolution.title)\(fps)"
                entries.append(
                    .init(
                        "\(resolution.title) at \(fps) fps",
                        "Settings › Record Video",
                        "\(resolution.aliases) \(fps) fps \(compactName) video resolution frame rate",
                        "video.fill",
                        .red,
                        .recordVideo
                    )
                )
            }
        }

        for resolution in ["1080p HD", "720p HD"] {
            for fps in [240, 120] {
                entries.append(
                    .init(
                        "\(resolution) at \(fps) fps Slo-Mo",
                        "Settings › Record Slo-Mo",
                        "slow motion slo mo slowmo \(resolution) \(fps) fps \(resolution.replacingOccurrences(of: " HD", with: ""))\(fps)",
                        "slowmo",
                        .orange,
                        .slowMotion
                    )
                )
            }
        }

        for megapixels in CameraManager.photoMegapixelPresets {
            entries.append(
                .init(
                    "\(megapixels) MP",
                    "Settings › Photo Capture",
                    "\(megapixels)mp \(megapixels) megapixel photo resolution",
                    "camera.fill",
                    .green,
                    .photoCapture
                )
            )
        }

        for count in CameraManager.photoBurstCountOptions {
            entries.append(
                .init(
                    "\(count) Photos per Burst",
                    "Settings › Photo Capture",
                    "burst \(count) photos count",
                    "camera.fill",
                    .green,
                    .photoCapture
                )
            )
        }

        for mode in ["Off", "Auto", "On"] {
            entries.append(.init("Photo Flash: \(mode)", "Settings › Photo Capture", "flash \(mode)", "camera.fill", .green, .photoCapture))
        }
        for timer in ["Off", "3 seconds", "10 seconds"] {
            entries.append(.init("Timer: \(timer)", "Settings › Preferences", "photo shutter timer delay \(timer)", "timer", .orange, .preferences))
        }
        for strength in ["Low", "Medium", "Strong"] {
            entries.append(.init("Haptic Strength: \(strength)", "Settings › Preferences", "haptic strength \(strength)", "waveform.path.ecg", .orange, .preferences))
        }
        for appearance in ["System", "Light", "Dark"] {
            entries.append(.init("Appearance: \(appearance)", "Settings › Appearance", "theme app appearance \(appearance)", "sun.max.fill", .gray, .appearance))
        }
        for accent in ["Ice", "Sunset", "Mint", "Lavender", "Coral", "Custom"] {
            entries.append(.init("Camera Accent: \(accent)", "Settings › Appearance", "camera accent color \(accent)", "sun.max.fill", .purple, .appearance))
        }
        for zoom in ["Slow", "Normal", "Fast"] {
            entries.append(.init("Zoom Speed: \(zoom)", "Settings › Preferences", "zoom speed \(zoom)", "plus.magnifyingglass", .blue, .preferences))
        }
        for size in ["Compact", "Large"] {
            entries.append(.init("HUD Text Size: \(size)", "Settings › Camera HUD › Appearance", "hud text size \(size)", "text.line.first.and.arrowtriangle.forward", .purple, .cameraHUD))
        }
        for size in ["Compact", "Normal"] {
            entries.append(.init("Live Stats Panel Size: \(size)", "Settings › Advanced Recording › Live Stats", "live stats panel size \(size)", "chart.bar.fill", .blue, .liveStats))
        }
        for minutes in [0, 15, 30, 60, 120] {
            let label = minutes == 0 ? "Off" : minutes == 60 ? "Every hour" : minutes == 120 ? "Every 2 hours" : "Every \(minutes) minutes"
            entries.append(.init("Split Recording: \(label)", "Settings › Advanced Recording", "split recording \(minutes) minutes \(label)", "waveform.path.ecg", .purple, .advancedRecording))
        }

        return entries
    }()

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

enum SettingsSearchDestination: Hashable {
    case cameraSetup
    case appearance
    case recordVideo
    case codecCompression
    case slowMotion
    case photoCapture
    case quickControls
    case preferences
    case zoomControls
    case cameraHUD
    case advancedRecording
    case liveStats
    case videoPresets
    case diagnostics
    case about
}

struct SettingsSearchEntry: Identifiable {
    let id: String
    let title: String
    let path: String
    let keywords: String
    let symbol: String
    let color: Color
    let destination: SettingsSearchDestination

    init(
        _ title: String,
        _ path: String,
        _ keywords: String,
        _ symbol: String,
        _ color: Color,
        _ destination: SettingsSearchDestination
    ) {
        self.id = "\(path)|\(title)"
        self.title = title
        self.path = path
        self.keywords = keywords
        self.symbol = symbol
        self.color = color
        self.destination = destination
    }

    private var searchText: String {
        "\(title) \(path) \(keywords)"
    }

    func matches(_ query: String) -> Bool {
        let normalizedQuery = Self.normalize(query)
        guard !normalizedQuery.isEmpty else { return false }
        let haystack = Self.normalize(searchText)
        if haystack.contains(normalizedQuery) { return true }

        let compactQuery = normalizedQuery.replacingOccurrences(of: " ", with: "")
        let compactHaystack = haystack.replacingOccurrences(of: " ", with: "")
        if compactQuery.count >= 2, compactHaystack.contains(compactQuery) { return true }

        let tokens = normalizedQuery.split(separator: " ").map(String.init)
        return !tokens.isEmpty && tokens.allSatisfy { haystack.contains($0) }
    }

    func score(for query: String) -> Int {
        let normalizedQuery = Self.normalize(query)
        let normalizedTitle = Self.normalize(title)
        let normalizedKeywords = Self.normalize(keywords)
        let compactQuery = normalizedQuery.replacingOccurrences(of: " ", with: "")
        let compactTitle = normalizedTitle.replacingOccurrences(of: " ", with: "")
        var score = 0

        if normalizedTitle == normalizedQuery { score += 1_000 }
        if normalizedTitle.hasPrefix(normalizedQuery) { score += 500 }
        if normalizedTitle.contains(normalizedQuery) { score += 350 }
        if compactQuery.count >= 2, compactTitle.contains(compactQuery) { score += 325 }
        if normalizedKeywords.contains(normalizedQuery) { score += 250 }

        for rawToken in normalizedQuery.split(separator: " ") {
            let token = String(rawToken)
            if normalizedTitle.contains(token) { score += 60 }
            else if normalizedKeywords.contains(token) { score += 35 }
        }
        return score
    }

    private static func normalize(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
