import SwiftUI

struct VideoSettingsView: View {
    @Environment(\.cameraTint) private var theme
    @ObservedObject var camera: CameraManager
    var positionStats: () -> Void = {}
    @AppStorage("photoAspect") private var photoAspect = "4:3"
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

                    SettingsCard(title: "More Settings", symbol: "slider.horizontal.3") {
                        if camera.captureMode == .video {
                            NavigationLink { VideoPresetsView(camera: camera) } label: {
                                SettingsNavigationRow(
                                    title: "Video Presets",
                                    subtitle: "Choose a ready-to-shoot setup",
                                    symbol: "wand.and.stars"
                                )
                            }
                            .buttonStyle(.plain)
                            SettingsDivider()
                        }

                        NavigationLink { CapturePreferencesView(camera: camera) } label: {
                            SettingsNavigationRow(
                                title: "Capture",
                                subtitle: "Timer, zoom, haptics and capture behavior",
                                symbol: "camera.badge.ellipsis"
                            )
                        }
                        .buttonStyle(.plain)

                        SettingsDivider()

                        NavigationLink { ViewfinderHUDSettingsMenu(camera: camera) } label: {
                            SettingsNavigationRow(
                                title: "Viewfinder & HUD",
                                subtitle: "Guides, level, HUD and screen behavior",
                                symbol: "viewfinder"
                            )
                        }
                        .buttonStyle(.plain)

                        SettingsDivider()

                        NavigationLink { AppearanceSettingsView() } label: {
                            SettingsNavigationRow(
                                title: "Appearance",
                                subtitle: "Theme and custom accent color",
                                symbol: "paintpalette.fill"
                            )
                        }
                        .buttonStyle(.plain)

                        if camera.captureMode != .photo {
                            SettingsDivider()
                            NavigationLink {
                                AdvancedRecordingSettingsView(camera: camera, positionStats: positionStats)
                            } label: {
                                SettingsNavigationRow(
                                    title: "Advanced Recording",
                                    subtitle: "Split clips, longevity and diagnostics",
                                    symbol: "waveform.path.ecg"
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    if camera.recoverableRecordingCount > 0 {
                        SettingsCard(title: "Recovery", symbol: "arrow.clockwise.circle.fill") {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("\(camera.recoverableRecordingCount) recording\(camera.recoverableRecordingCount == 1 ? "" : "s") waiting")
                                        .font(.subheadline.weight(.semibold))
                                    Text("Retry saving recordings that Photos could not import earlier.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Retry") { camera.retryRecoverableRecordings() }
                                    .font(.caption.weight(.bold))
                                    .buttonStyle(.borderedProminent)
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .tint(theme)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
        .onChange(of: photoAspect) { _, _ in
            camera.refreshPhotoResolutionForCurrentAspect()
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
                Text("\(camera.captureMode.rawValue) • \(camera.cameraPosition == .back ? "Rear" : "Front")")
                    .font(.headline)
                Text(qualitySummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
        }
        .padding(14)
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(theme.opacity(0.16), lineWidth: 1)
                .allowsHitTesting(false)
        }
    }

    private var videoQualitySettings: some View {
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
            SettingsDivider()
            ThemeMenu(
                title: "Compression",
                selection: $camera.videoCompression,
                options: VideoCompression.allCases.map { ($0, $0.rawValue) }
            )
            SettingsDivider()
            ThemeMenu(
                title: "Codec",
                selection: $camera.selectedVideoCodec,
                options: [("HEVC", "HEVC"), ("H264", "H.264")]
            )
            if let message = camera.codecAvailabilityMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("High uses native encoder defaults. Medium and Data Saver trade bitrate for smaller files.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var slowMotionSettings: some View {
        SettingsCard(title: "Slo-Mo Quality", symbol: "slowmo") {
            if camera.cameraPosition == .back && camera.minimumZoomFactor >= 1 {
                Text("0.5× appears only when Ultra Wide supports the selected resolution and capture FPS.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
                SettingsDivider()
                ThemeMenu(
                    title: "Compression",
                    selection: $camera.videoCompression,
                    options: VideoCompression.allCases.map { ($0, $0.rawValue) }
                )
                SettingsDivider()
                ThemeMenu(
                    title: "Codec",
                    selection: $camera.selectedVideoCodec,
                    options: [("HEVC", "HEVC"), ("H264", "H.264")]
                )
                if let message = camera.codecAvailabilityMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var photoSettings: some View {
        SettingsCard(title: "Photo Quality", symbol: "camera.fill") {
            PhotoResolutionPicker(camera: camera)
            Text("Lower MP choices are clean downsizes from the active camera's maximum-quality still.")
                .font(.caption)
                .foregroundStyle(.secondary)
            SettingsDivider()
            ThemeMenu(
                title: "Aspect",
                selection: $photoAspect,
                options: [("4:3", "4:3"), ("1:1", "1:1")]
            )
            SettingsDivider()
            ThemeMenu(
                title: "Format",
                selection: $camera.photoFileFormat,
                options: [("HEIC", "HEIC"), ("JPEG", "JPEG")]
            )
            Text("HEIC uses less storage. JPEG offers broader compatibility.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var qualitySummary: String {
        switch camera.captureMode {
        case .video:
            return "\(camera.selectedResolution.rawValue) • \(camera.selectedFrameRate.label) • \(camera.selectedVideoCodec)"
        case .sloMo:
            return "\(camera.selectedSlowMotionResolution.rawValue) • \(camera.selectedSlowMotionFrameRate.label) • \(camera.selectedVideoCodec)"
        case .photo:
            return "\(camera.currentPhotoResolutionLabel) • \(photoAspect) • \(camera.photoFileFormat)"
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

private struct PhotoResolutionPicker: View {
    @Environment(\.cameraTint) private var theme
    @ObservedObject var camera: CameraManager

    private var selectedOption: CameraManager.PhotoResolutionOption? {
        camera.supportedPhotoResolutions.first { $0.id == camera.selectedPhotoResolutionID }
    }

    private var maximumOptionLabel: String {
        guard let maximum = camera.supportedPhotoResolutions.first(where: { $0.id == "max" }) else {
            return "MAX"
        }
        return "MAX · \(PhotoResolutionCatalog.label(for: maximum.dimensions))"
    }

    private func label(for option: CameraManager.PhotoResolutionOption) -> String {
        option.id == "max" ? maximumOptionLabel : option.label
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Photo Resolution")
                    .font(.subheadline.weight(.semibold))
                Text("Captured from the maximum-quality camera source")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)

            if camera.supportedPhotoResolutions.isEmpty {
                ProgressView().controlSize(.small)
            } else {
                Menu {
                    ForEach(camera.supportedPhotoResolutions) { option in
                        Button {
                            guard option.id != camera.selectedPhotoResolutionID else { return }
                            camera.selectPhotoResolution(option)
                        } label: {
                            if option.id == camera.selectedPhotoResolutionID {
                                Label(label(for: option), systemImage: "checkmark")
                            } else {
                                Text(label(for: option))
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(selectedOption.map { label(for: $0) } ?? camera.currentPhotoResolutionLabel)
                            .font(.caption.weight(.bold))
                            .lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 10, weight: .bold))
                    }
                    .foregroundStyle(theme)
                    .padding(.horizontal, 12)
                    .frame(minWidth: 112, minHeight: 44)
                    .background(theme.opacity(0.13), in: Capsule())
                    .contentShape(Rectangle())
                }
            }
        }
        .frame(minHeight: 52)
    }
}

private struct ViewfinderHUDSettingsMenu: View {
    @Environment(\.cameraTint) private var theme
    @ObservedObject var camera: CameraManager
    @AppStorage("cameraGridEnabled") private var isGridEnabled = false
    @AppStorage("gridOpacity") private var gridOpacity = 1.0
    @AppStorage("levelMeterEnabled") private var isLevelMeterEnabled = true
    @AppStorage("centerCrosshair") private var centerCrosshair = false
    @AppStorage("keepScreenAwakeEnabled") private var keepScreenAwakeEnabled = false
    @AppStorage("cameraHUDEnabled") private var isHUDEnabled = true
    @AppStorage("cameraHUDResolution") private var hudResolution = true
    @AppStorage("cameraHUDFPS") private var hudFPS = true
    @AppStorage("cameraHUDRemaining") private var hudRemaining = true
    @AppStorage("cameraHUDWhiteBalance") private var hudWhiteBalance = false
    @AppStorage("cameraHUDBattery") private var hudBattery = false
    @AppStorage("cameraHUDStorage") private var hudStorage = false
    @AppStorage("cameraHUDDroppedFrames") private var hudDroppedFrames = false
    @AppStorage("cameraHUDAudioMeter") private var hudAudioMeter = false
    @AppStorage("thermalHUD") private var hudThermal = false
    @AppStorage("hudTextSize") private var hudTextSize = 10.0

    var body: some View {
        SettingsPage {
            SettingsCard(title: "Guides", symbol: "viewfinder") {
                SettingsToggleRow(
                    title: "Grid",
                    subtitle: "Rule-of-thirds composition guides",
                    isOn: $isGridEnabled
                )
                if isGridEnabled {
                    HStack(spacing: 10) {
                        Text("Opacity").font(.caption)
                        Slider(value: $gridOpacity, in: 0.2...1)
                        Text("\(Int(gridOpacity * 100))%")
                            .font(.caption.monospacedDigit())
                            .frame(width: 38)
                    }
                    .frame(minHeight: 44)
                    .tint(theme)
                }
                SettingsDivider()
                SettingsToggleRow(
                    title: "Level",
                    subtitle: "Keep the horizon straight",
                    isOn: $isLevelMeterEnabled
                )
                SettingsDivider()
                SettingsToggleRow(
                    title: "Center Crosshair",
                    subtitle: "Show a small center aiming mark",
                    isOn: $centerCrosshair
                )
            }

            SettingsCard(title: "Camera HUD", symbol: "capsule.fill") {
                SettingsToggleRow(
                    title: "Show Camera HUD",
                    subtitle: "Compact live info between Flash and Settings",
                    isOn: $isHUDEnabled
                )

                if isHUDEnabled {
                    SettingsDivider()
                    ThemeMenu(
                        title: "Text Size",
                        selection: $hudTextSize,
                        options: [(10.0, "Compact"), (12.0, "Large")]
                    )
                    SettingsDivider()
                    SettingsToggleRow(title: "Resolution", subtitle: "Show active capture resolution", isOn: $hudResolution)
                    if camera.captureMode != .photo {
                        SettingsDivider()
                        SettingsToggleRow(title: "FPS", subtitle: "Show selected capture frame rate", isOn: $hudFPS)
                    }
                    SettingsDivider()
                    SettingsToggleRow(title: "Remaining", subtitle: camera.captureMode == .photo ? "Estimate photos remaining" : "Estimate recording time remaining", isOn: $hudRemaining)
                    SettingsDivider()
                    SettingsToggleRow(title: "White Balance", subtitle: "Show active white-balance preset", isOn: $hudWhiteBalance)
                    SettingsDivider()
                    SettingsToggleRow(title: "Battery", subtitle: "Show battery percentage", isOn: $hudBattery)
                    SettingsDivider()
                    SettingsToggleRow(title: "Free Storage", subtitle: "Show available device storage", isOn: $hudStorage)
                    SettingsDivider()
                    SettingsToggleRow(title: "Thermal Status", subtitle: "Show current thermal state", isOn: $hudThermal)
                    if camera.captureMode != .photo {
                        SettingsDivider()
                        SettingsToggleRow(title: "Frame Gaps", subtitle: "Analyze the last saved clip for frame gaps", isOn: $hudDroppedFrames)
                        SettingsDivider()
                        SettingsToggleRow(title: "Audio Meter", subtitle: "Microphone level meter while recording", isOn: $hudAudioMeter)
                    }
                } else {
                    Text("HUD item choices stay saved while the HUD is hidden.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            SettingsCard(title: "Screen Behavior", symbol: "display") {
                SettingsToggleRow(
                    title: "Keep Screen Awake",
                    subtitle: "Prevent Auto-Lock while LowPolyCam is open",
                    isOn: $keepScreenAwakeEnabled
                )
            }
        }
        .navigationTitle("Viewfinder & HUD")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: isHUDEnabled) { _, _ in camera.refreshAuxiliaryOutputs() }
        .onChange(of: hudAudioMeter) { _, _ in camera.refreshAuxiliaryOutputs() }
        .onChange(of: hudDroppedFrames) { _, _ in camera.refreshAuxiliaryOutputs() }
    }
}

struct SettingsNavigationRow: View {
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

private struct SettingsPickerRow<Option: Identifiable & Equatable>: View where Option.ID: Hashable {
    let title: String
    let options: [Option]
    let selection: Option
    let label: (Option) -> String
    let onSelect: (Option) -> Void

    private var optionPairs: [(Option.ID, String)] {
        options.map { ($0.id, label($0)) }
    }

    private var selectionBinding: Binding<Option.ID> {
        Binding(
            get: { selection.id },
            set: { id in
                guard id != selection.id,
                      let option = options.first(where: { $0.id == id }) else { return }
                onSelect(option)
            }
        )
    }

    var body: some View {
        SettingsSelectionControl(
            title: title,
            selection: selectionBinding,
            options: optionPairs
        )
    }
}
