import SwiftUI

struct VideoSettingsView: View {
    @Environment(\.cameraTint) private var theme
    @ObservedObject var camera: CameraManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    modeHeader

                    switch camera.captureMode {
                    case .video:
                        videoQualitySettings
                    case .sloMo:
                        slowMotionSettings
                    case .photo:
                        photoSettings
                    }

                    QuickCameraSettings(camera: camera)

                    SettingsCard(title: "Settings", symbol: "slider.horizontal.3") {
                        if camera.captureMode == .video {
                            NavigationLink { VideoPresetsView(camera: camera) } label: {
                                SettingsNavigationRow(title: "Video Presets", subtitle: "Choose a ready-to-shoot setup", symbol: "wand.and.stars")
                            }.buttonStyle(.plain)
                            SettingsDivider()
                        }
                        NavigationLink { AppearanceSettingsView() } label: {
                            SettingsNavigationRow(title: "Appearance", subtitle: "Theme and custom accent color", symbol: "paintpalette.fill")
                        }.buttonStyle(.plain)
                        SettingsDivider()
                        NavigationLink {
                            CapturePreferencesView(camera: camera)
                        } label: {
                            SettingsNavigationRow(title: "Capture Controls", subtitle: "Timer, zoom, recording and haptics", symbol: "paintpalette.fill")
                        }.buttonStyle(.plain)
                        SettingsDivider()
                        NavigationLink {
                            CameraSettingsMenu(camera: camera)
                        } label: {
                            SettingsNavigationRow(
                                title: "Camera",
                                subtitle: "Viewfinder, stabilization and camera behavior",
                                symbol: "camera.fill"
                            )
                        }
                        .buttonStyle(.plain)

                        SettingsDivider()

                        NavigationLink {
                            CameraHUDSettingsMenu(camera: camera)
                        } label: {
                            SettingsNavigationRow(
                                title: "Camera HUD",
                                subtitle: "Choose what appears in the top info pill",
                                symbol: "capsule.fill"
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .tint(theme)
            .accentColor(theme)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
    }

    private var modeHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: modeSymbol)
                .font(.system(size: 20, weight: .semibold))
                .frame(width: 42, height: 42)
                .background(theme.opacity(0.16), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .foregroundStyle(theme)

            VStack(alignment: .leading, spacing: 2) {
                Text(camera.captureMode.rawValue)
                    .font(.headline)
                Text("Camera settings")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var videoQualitySettings: some View {
        VStack(spacing: 18) {
          SettingsCard(title: "Video Quality", symbol: "video.fill") {
            SettingsPickerRow(
                title: "Resolution",
                options: camera.supportedResolutions,
                selection: camera.selectedResolution,
                label: { $0.rawValue },
                onSelect: camera.selectResolution
            )

            SettingsDivider()

            SettingsPickerRow(
                title: "Frame Rate",
                options: camera.supportedFrameRates,
                selection: camera.selectedFrameRate,
                label: { $0.label },
                onSelect: camera.selectFrameRate
            )
        }
        }
    }

    private var slowMotionSettings: some View {
        SettingsCard(title: "Slo-Mo Quality", symbol: "slowmo") {
            if camera.supportedSlowMotionResolutions.isEmpty {
                Text("Slo-Mo isn’t available on this camera.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                SettingsPickerRow(
                    title: "Resolution",
                    options: camera.supportedSlowMotionResolutions,
                    selection: camera.selectedSlowMotionResolution,
                    label: { $0.rawValue },
                    onSelect: camera.selectSlowMotionResolution
                )

                SettingsDivider()

                SettingsPickerRow(
                    title: "Frame Rate",
                    options: camera.supportedSlowMotionFrameRates,
                    selection: camera.selectedSlowMotionFrameRate,
                    label: { $0.label },
                    onSelect: camera.selectSlowMotionFrameRate
                )
            }
        }
    }

    private var photoSettings: some View {
        SettingsCard(title: "Photo", symbol: "camera.fill") {
            ThemeMenu(title: "Save Format", selection: $camera.photoFileFormat, options: [("HEIC", "HEIC"), ("JPEG", "JPEG")])
            Text("HEIC uses less storage. JPEG offers broader compatibility. Unsupported HEIC capture falls back to JPEG.")
                .font(.caption).foregroundStyle(.secondary)
            SettingsDivider()
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Photo Quality")
                        .font(.subheadline.weight(.semibold))
                    Text("Uses the maximum resolution supported by the active camera")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(camera.currentPhotoResolutionLabel)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(theme)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(theme.opacity(0.13), in: Capsule())
            }
        }
    }

    private var modeSymbol: String {
        switch camera.captureMode {
        case .video: return "video.fill"
        case .photo: return "camera.fill"
        case .sloMo: return "slowmo"
        }
    }
}

private struct CameraSettingsMenu: View {
    @Environment(\.cameraTint) private var theme
    @ObservedObject var camera: CameraManager
    @AppStorage("cameraGridEnabled") private var isGridEnabled = false
    @AppStorage("levelMeterEnabled") private var isLevelMeterEnabled = true
    @AppStorage("hapticCaptureEnabled") private var isHapticCaptureEnabled = true
    @AppStorage("keepScreenAwakeEnabled") private var keepScreenAwakeEnabled = false

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                QuickCameraSettings(camera: camera)

                SettingsCard(title: "Camera Experience", symbol: "sparkles") {
                    SettingsToggleRow(
                        title: "Haptic Capture",
                        subtitle: camera.captureMode == .photo ? "Feel a tap when taking a photo" : "Feel a tap when starting or stopping recording",
                        isOn: $isHapticCaptureEnabled
                    )

                    SettingsDivider()

                    SettingsToggleRow(
                        title: "Keep Screen Awake",
                        subtitle: "Prevent Auto-Lock while LowPolyCam is open",
                        isOn: $keepScreenAwakeEnabled
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("Camera")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct CameraHUDSettingsMenu: View {
    @Environment(\.cameraTint) private var theme
    @ObservedObject var camera: CameraManager
    @AppStorage("cameraHUDEnabled") private var isHUDEnabled = true
    @AppStorage("cameraHUDResolution") private var hudResolution = true
    @AppStorage("cameraHUDFPS") private var hudFPS = true
    @AppStorage("cameraHUDRemaining") private var hudRemaining = true
    @AppStorage("cameraHUDWhiteBalance") private var hudWhiteBalance = false
    @AppStorage("cameraHUDBattery") private var hudBattery = false
    @AppStorage("cameraHUDStorage") private var hudStorage = false
    @AppStorage("cameraHUDDroppedFrames") private var hudDroppedFrames = false

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                SettingsCard(title: "Camera HUD", symbol: "capsule.fill") {
                    SettingsToggleRow(
                        title: "Show Camera HUD",
                        subtitle: "Compact live info between Flash and Settings",
                        isOn: $isHUDEnabled
                    )
                }

                if isHUDEnabled {
                    SettingsCard(title: "HUD Information", symbol: "text.line.first.and.arrowtriangle.forward") {
                        SettingsToggleRow(title: "Battery", subtitle: "Show the current battery percentage", isOn: $hudBattery)
                        SettingsDivider()
                        SettingsToggleRow(title: "Free Storage", subtitle: "Show available space on this iPhone", isOn: $hudStorage)
                        if camera.captureMode != .photo {
                            SettingsDivider()
                            SettingsToggleRow(title: "Frame Gaps", subtitle: "Check the last saved clip for missing frame intervals; not a live counter", isOn: $hudDroppedFrames)
                        }
                        SettingsDivider()
                        SettingsToggleRow(
                            title: "Resolution",
                            subtitle: camera.captureMode == .photo ? "Show current maximum photo resolution" : "Show selected video resolution",
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
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .tint(theme)
        .accentColor(theme)
        .navigationTitle("Camera HUD")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct SettingsNavigationRow: View {
    @Environment(\.cameraTint) private var theme
    let title: String
    let subtitle: String
    let symbol: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(theme)
                .frame(width: 34, height: 34)
                .background(theme.opacity(0.13), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}

struct SettingsCard<Content: View>: View {
    @Environment(\.cameraTint) private var theme
    let title: String
    let symbol: String
    let content: Content

    init(title: String, symbol: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.secondary)

            content
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.primary.opacity(0.05), lineWidth: 1)
        }
    }
}

struct SettingsDivider: View {
    @Environment(\.cameraTint) private var theme
    var body: some View {
        Divider().opacity(0.55)
    }
}

struct SettingsToggleRow: View {
    @Environment(\.cameraTint) private var theme
    let title: String
    let subtitle: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .tint(theme)
        .frame(minHeight: 52)
    }
}

private struct SettingsPickerRow<Option: Identifiable & Equatable>: View {
    @Environment(\.cameraTint) private var theme
    let title: String
    let options: [Option]
    let selection: Option
    let label: (Option) -> String
    let onSelect: (Option) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.subheadline.weight(.semibold))

            HStack(spacing: 8) {
                ForEach(options) { option in
                    Button {
                        onSelect(option)
                    } label: {
                        Text(label(option))
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .background(
                                selection == option ? theme : Color.primary.opacity(0.07),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                            )
                            .foregroundStyle(selection == option ? .black : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
