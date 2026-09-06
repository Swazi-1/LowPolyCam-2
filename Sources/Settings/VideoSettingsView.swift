import SwiftUI

struct VideoSettingsView: View {
    @Environment(\.cameraTint) private var theme
    @ObservedObject var camera: CameraManager
    var positionStats: () -> Void = {}
    @AppStorage("photoAspect") private var photoAspect = "4:3"
    @AppStorage("burstCount") private var burstCount = 5
    @AppStorage("photoShutterDelay") private var photoShutterDelay = 0
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
                    RecordingExtrasSettings(camera: camera, positionStats: positionStats)

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
                                Button("Retry") {
                                    camera.retryRecoverableRecordings()
                                }
                                .font(.caption.weight(.bold))
                                .buttonStyle(.borderedProminent)
                            }
                        }
                    }

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
                            SettingsNavigationRow(title: "Capture Controls", subtitle: "Timer, zoom, recording and haptics", symbol: "slider.horizontal.3")
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
            if camera.cameraPosition == .back && camera.minimumZoomFactor >= 1 {
                Text("0.5× is available only when the Ultra Wide lens supports this Slo-Mo quality and frame rate.")
                    .font(.caption).foregroundStyle(.secondary)
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
            }
        }
    }

    private var photoSettings: some View {
        SettingsCard(title: "Photo", symbol: "camera.fill") {
            PhotoResolutionPicker(camera: camera)
            Text("Max uses the active camera's highest-quality still. Lower choices are clean downsizes from Max and always keep the selected aspect ratio.")
                .font(.caption)
                .foregroundStyle(.secondary)
            SettingsDivider()
            ThemeMenu(title: "Aspect Ratio", selection: $photoAspect, options: [("4:3", "4:3"), ("1:1", "1:1")])
            ThemeMenu(title: "Photo Timer", selection: $photoShutterDelay, options: [(0, "Off"), (3, "3 seconds"), (5, "5 seconds"), (10, "10 seconds")])
            Text("The countdown appears around the shutter. Tap it again to cancel.")
                .font(.caption)
                .foregroundStyle(.secondary)
            SettingsDivider()
            ThemeMenu(title: "Burst Photos", selection: $burstCount, options: [(5, "5"), (10, "10"), (15, "15")])
            Text("Hold the shutter to start a burst, then release to stop after the current shot finishes. Photos continue saving in the background.").font(.caption).foregroundStyle(.secondary)
            SettingsDivider()
            ThemeMenu(title: "Save Format", selection: $camera.photoFileFormat, options: [("HEIC", "HEIC"), ("JPEG", "JPEG")])
            Text("HEIC uses less storage. JPEG offers broader compatibility. Unsupported HEIC capture falls back to JPEG.")
                .font(.caption).foregroundStyle(.secondary)
            SettingsDivider()
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Active Photo Size")
                        .font(.subheadline.weight(.semibold))
                    Text("Applies to the current camera lens")
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

private struct PhotoResolutionPicker: View {
    @Environment(\.cameraTint) private var theme
    @ObservedObject var camera: CameraManager

    private var selectedOption: CameraManager.PhotoResolutionOption? {
        camera.supportedPhotoResolutions.first { $0.id == camera.selectedPhotoResolutionID }
    }

    private var nativeSelection: Binding<String> {
        Binding(
            get: { camera.selectedPhotoResolutionID },
            set: { id in
                guard id != camera.selectedPhotoResolutionID,
                      let option = camera.supportedPhotoResolutions.first(where: { $0.id == id }) else { return }
                camera.selectPhotoResolution(option)
            }
        )
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
                    Picker("Photo Resolution", selection: nativeSelection) {
                        ForEach(camera.supportedPhotoResolutions) { option in
                            Text(option.label).tag(option.id)
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(selectedOption?.id == "max" ? "Max · \(camera.currentPhotoResolutionLabel)" : (selectedOption?.label ?? camera.currentPhotoResolutionLabel))
                            .font(.caption.weight(.bold))
                            .lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 10, weight: .bold))
                    }
                    .foregroundStyle(theme)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(theme.opacity(0.13), in: Capsule())
                }
            }
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
    @AppStorage("cameraHUDAudioMeter") private var hudAudioMeter = false
    @AppStorage("thermalHUD") private var hudThermal = false
    @AppStorage("hudTextSize") private var hudTextSize = 10.0

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
                        SettingsDivider()
                        SettingsToggleRow(title: "Thermal Status", subtitle: "Show the current device thermal state", isOn: $hudThermal)
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

                            SettingsDivider()
                            SettingsToggleRow(
                                title: "Audio Meter",
                                subtitle: "A tiny microphone level meter while recording Video or Slo-Mo",
                                isOn: $hudAudioMeter
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
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .tint(theme)
        .accentColor(theme)
        .navigationTitle("Camera HUD")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: hudAudioMeter) { _, _ in camera.refreshAuxiliaryOutputs() }
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

private struct SettingsPickerRow<Option: Identifiable & Equatable>: View {
    @Environment(\.cameraTint) private var theme
    let title: String
    let options: [Option]
    let selection: Option
    let label: (Option) -> String
    let onSelect: (Option) -> Void

    private var nativeSelection: Binding<Option.ID> {
        Binding(
            get: { selection.id },
            set: { id in
                guard id != selection.id, let option = options.first(where: { $0.id == id }) else { return }
                onSelect(option)
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.subheadline.weight(.semibold))

            Menu {
                Picker(title, selection: nativeSelection) {
                    ForEach(options) { option in
                        Text(label(option)).tag(option.id)
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Text(label(selection))
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10, weight: .bold))
                }
                .foregroundStyle(theme)
                .padding(.horizontal, 11)
                .frame(maxWidth: .infinity, minHeight: 38)
                .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .contentShape(Rectangle())
            }
            .disabled(options.isEmpty)
        }
    }
}
