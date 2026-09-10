import SwiftUI

struct CameraSetupSettingsView: View {
    @ObservedObject var camera: CameraManager
    @AppStorage("rememberCaptureMode") private var rememberCameraSetup = false
    @AppStorage("keepScreenAwakeEnabled") private var keepScreenAwakeEnabled = false

    var body: some View {
        List {
            Section {
                Toggle(isOn: $rememberCameraSetup) {
                    SettingsToggleLabel(
                        symbol: "arrow.counterclockwise.circle.fill",
                        color: .green,
                        title: "Remember Camera Setup",
                        subtitle: "Restore your camera setup when LowPolyCam opens."
                    )
                }
                .onChange(of: rememberCameraSetup) { _, enabled in
                    camera.setRememberCameraSetupEnabled(enabled)
                }
                Text("Enable this to reveal the setup options that can be changed and remembered below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if rememberCameraSetup {
                Section("CAPTURE MODE") {
                    Picker("Capture Mode", selection: captureModeBinding) {
                        ForEach(CameraManager.CaptureMode.allCases.filter { camera.isCaptureModeSupported($0) }) { mode in
                            Text(displayName(for: mode)).tag(mode.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .disabled(!cameraControlsEnabled)
                }
            }

            Section("DISPLAY") {
                Toggle(isOn: $keepScreenAwakeEnabled) {
                    SettingsToggleLabel(
                        symbol: "sun.max.fill",
                        color: .orange,
                        title: "Keep Screen Awake",
                        subtitle: "Prevent Auto-Lock while LowPolyCam is open."
                    )
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Camera Setup")
        .navigationBarTitleDisplayMode(.large)
        .tint(.blue)
    }

    private var cameraControlsEnabled: Bool {
        !camera.isRecording &&
        !camera.isRecordingStarting &&
        !camera.isFinalizingRecording &&
        !camera.isCapturingPhoto &&
        !camera.isPreviewTransitioning &&
        !camera.isLensTransitioning
    }

    private var captureModeBinding: Binding<String> {
        Binding(
            get: { camera.captureMode.id },
            set: { rawValue in
                guard let mode = CameraManager.CaptureMode.allCases.first(where: { $0.id == rawValue }) else { return }
                camera.selectCaptureMode(mode)
            }
        )
    }

    private func displayName(for mode: CameraManager.CaptureMode) -> String {
        switch mode {
        case .video: return "Video"
        case .photo: return "Photo"
        case .sloMo: return "Slo-Mo"
        }
    }
}

struct RecordVideoSettingsView: View {
    @ObservedObject var camera: CameraManager

    private var formatOptions: [VideoFormatOption] {
        camera.capabilitySnapshot.videoPairs
            .map { VideoFormatOption(resolution: $0.resolution, frameRate: $0.frameRate) }
            .sorted { lhs, rhs in
                let left = formatSortKey(lhs)
                let right = formatSortKey(rhs)
                return left > right
            }
    }

    private func formatSortKey(_ option: VideoFormatOption) -> Int {
        let resolutionRank: Int
        switch option.resolution {
        case .p4k: resolutionRank = 3
        case .p1080: resolutionRank = 2
        case .p720: resolutionRank = 1
        }
        return resolutionRank * 1_000 + option.frameRate.rawValue
    }

    var body: some View {
        List {
            Section {
                if camera.isCapabilitySnapshotLoading && !camera.capabilitySnapshot.isReady {
                    ProgressView("Checking camera formats…")
                } else if formatOptions.isEmpty {
                    Text("No supported video formats are available for this camera.")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Format", selection: videoFormatBinding) {
                        ForEach(formatOptions) { option in
                            Text(formatName(option.resolution, option.frameRate)).tag(option.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .disabled(!formatControlsEnabled)
                }
            } header: {
                Text("VIDEO QUALITY")
            } footer: {
                Text("Only combinations supported by the current front or rear camera are shown.")
            }

            Section("VIDEO SETTINGS") {
                NavigationLink {
                    CodecCompressionSettingsView(camera: camera)
                } label: {
                    SettingsNavigationLabel(
                        symbol: "internaldrive.fill",
                        color: .blue,
                        title: "Codec & Compression",
                        value: "\(camera.selectedVideoCodec == "HEVC" ? "HEVC" : "H.264") · \(camera.videoCompression.rawValue)"
                    )
                }
            }

            Section {
                Toggle(
                    isOn: Binding(
                        get: { camera.isVideoStabilizationEnabled },
                        set: { camera.setVideoStabilizationEnabled($0) }
                    )
                ) {
                    SettingsToggleLabel(
                        symbol: "dot.radiowaves.left.and.right",
                        color: .green,
                        title: "Stabilization",
                        subtitle: "Reduce camera shake while recording video."
                    )
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Record Video")
        .navigationBarTitleDisplayMode(.large)
        .tint(.blue)
    }

    private var formatControlsEnabled: Bool {
        !camera.isRecording &&
        !camera.isRecordingStarting &&
        !camera.isFinalizingRecording &&
        !camera.isLensTransitioning
    }

    private var videoFormatBinding: Binding<String> {
        Binding(
            get: { "\(camera.selectedResolution.rawValue)-\(camera.selectedFrameRate.rawValue)" },
            set: { id in
                guard let option = formatOptions.first(where: { $0.id == id }) else { return }
                camera.selectVideoFormat(resolution: option.resolution, frameRate: option.frameRate)
            }
        )
    }

    private func formatName(_ resolution: VideoResolution, _ frameRate: VideoFrameRate) -> String {
        switch resolution {
        case .p720: return "720p HD at \(frameRate.rawValue) fps"
        case .p1080: return "1080p HD at \(frameRate.rawValue) fps"
        case .p4k: return "4K at \(frameRate.rawValue) fps"
        }
    }
}

struct SlowMotionSettingsView: View {
    @ObservedObject var camera: CameraManager

    private var formatOptions: [SlowMotionFormatOption] {
        camera.capabilitySnapshot.slowMotionPairs.map {
            SlowMotionFormatOption(resolution: $0.resolution, frameRate: $0.frameRate)
        }.sorted { lhs, rhs in
            slowMotionSortKey(lhs) > slowMotionSortKey(rhs)
        }
    }

    private func slowMotionSortKey(_ option: SlowMotionFormatOption) -> Int {
        let resolutionRank: Int
        switch option.resolution {
        case .p1080: resolutionRank = 3
        case .p720: resolutionRank = 2
        case .p4k: resolutionRank = 1
        }
        return resolutionRank * 1_000 + option.frameRate.rawValue
    }

    var body: some View {
        List {
            Section {
                if camera.isCapabilitySnapshotLoading && !camera.capabilitySnapshot.isReady {
                    ProgressView("Checking Slo-Mo formats…")
                } else if formatOptions.isEmpty {
                    Text("Slo-Mo isn’t available on this camera.")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Format", selection: slowMotionFormatBinding) {
                        ForEach(formatOptions) { option in
                            Text(formatName(option.resolution, option.frameRate)).tag(option.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .disabled(!formatControlsEnabled)
                }
            } header: {
                Text("SLO-MO QUALITY")
            } footer: {
                Text("Slo-Mo uses HEVC automatically. Available resolutions and frame rates depend on the selected camera and lens.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Record Slo-Mo")
        .navigationBarTitleDisplayMode(.large)
        .tint(.blue)
    }

    private var formatControlsEnabled: Bool {
        !camera.isRecording &&
        !camera.isRecordingStarting &&
        !camera.isFinalizingRecording &&
        !camera.isLensTransitioning
    }

    private var slowMotionFormatBinding: Binding<String> {
        Binding(
            get: { "\(camera.selectedSlowMotionResolution.rawValue)-\(camera.selectedSlowMotionFrameRate.rawValue)" },
            set: { id in
                guard let option = formatOptions.first(where: { $0.id == id }) else { return }
                camera.selectSlowMotionFormat(resolution: option.resolution, frameRate: option.frameRate)
            }
        )
    }

    private func formatName(_ resolution: VideoResolution, _ frameRate: CameraManager.SlowMotionFrameRate) -> String {
        switch resolution {
        case .p720: return "720p HD at \(frameRate.rawValue) fps"
        case .p1080: return "1080p HD at \(frameRate.rawValue) fps"
        case .p4k: return "4K at \(frameRate.rawValue) fps"
        }
    }
}

struct PhotoCaptureSettingsView: View {
    @ObservedObject var camera: CameraManager
    @AppStorage("photoAspect") private var photoAspect = "4:3"
    @AppStorage("burstCount") private var burstCount = CameraManager.defaultPhotoBurstCount

    var body: some View {
        List {
            Section {
                Picker("Megapixels", selection: megapixelBinding) {
                    ForEach(camera.supportedPhotoMegapixels, id: \.self) { megapixels in
                        Text("\(megapixels) MP").tag(megapixels)
                    }
                }
                .pickerStyle(.menu)
            } header: {
                Text("PHOTO QUALITY")
            } footer: {
                Text("LowPolyCam keeps full sensor quality and saves at the selected megapixel count.")
            }

            Section("FORMAT") {
                Picker("Format", selection: photoFormatBinding) {
                    Text("HEIC").tag("HEIC")
                    Text("JPEG").tag("JPEG")
                }
                .pickerStyle(.menu)
            }

            Section("ASPECT RATIO") {
                Picker("Aspect Ratio", selection: $photoAspect) {
                    Text("4:3").tag("4:3")
                    Text("1:1").tag("1:1")
                }
                .pickerStyle(.menu)
                .onChange(of: photoAspect) { _, newValue in
                    camera.updatePhotoAspectSelection(newValue)
                }
            }

            Section {
                Picker("Photos per Burst", selection: $burstCount) {
                    ForEach(CameraManager.photoBurstCountOptions, id: \.self) { count in
                        Text("\(count)").tag(count)
                    }
                }
                .pickerStyle(.menu)
            } header: {
                Text("EXTRAS")
            } footer: {
                Text("Hold the shutter to start a burst and release it to stop early.")
            }

            Section {
                Picker("Flash", selection: photoFlashBinding) {
                    ForEach(CameraManager.PhotoFlashMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.menu)
            } header: {
                Text("FLASH")
            } footer: {
                Text("Flash is applied when the selected camera supports still-photo flash.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Photo Capture")
        .navigationBarTitleDisplayMode(.large)
        .tint(.blue)
        .onAppear { camera.updatePhotoAspectSelection(photoAspect) }
    }

    private var megapixelBinding: Binding<Int> {
        Binding(
            get: { camera.selectedPhotoMegapixels },
            set: { camera.selectPhotoMegapixels($0) }
        )
    }

    private var photoFormatBinding: Binding<String> {
        Binding(
            get: { camera.photoFileFormat },
            set: { camera.photoFileFormat = $0 }
        )
    }

    private var photoFlashBinding: Binding<String> {
        Binding(
            get: { camera.photoFlashMode.rawValue },
            set: { rawValue in
                guard let mode = CameraManager.PhotoFlashMode(rawValue: rawValue) else { return }
                camera.photoFlashMode = mode
            }
        )
    }
}

struct CodecCompressionSettingsView: View {
    @ObservedObject var camera: CameraManager

    var body: some View {
        List {
            Section {
                if camera.isCapabilitySnapshotLoading && !camera.capabilitySnapshot.isReady {
                    ProgressView("Checking codecs…")
                } else if availableCodecs.isEmpty {
                    Text("No video codec is available for the current camera format.")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Codec", selection: codecBinding) {
                        ForEach(availableCodecs, id: \.self) { codec in
                            Text(codec == "HEVC" ? "HEVC" : "H.264").tag(codec)
                        }
                    }
                    .pickerStyle(.menu)
                    .disabled(!codecControlsEnabled)
                }
            } header: {
                Text("CODEC")
            } footer: {
                Text("HEVC saves space efficiently and is required for some high-resolution or high-frame-rate combinations.")
            }

            Section {
                Picker("Compression", selection: compressionBinding) {
                    ForEach(VideoCompression.allCases) { compression in
                        Text(compression.rawValue).tag(compression.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .disabled(!codecControlsEnabled)
            } header: {
                Text("COMPRESSION")
            } footer: {
                Text("Data Saver creates smaller files. High uses more data to preserve detail.")
            }

            if let message = camera.codecAvailabilityMessage {
                Section {
                    SettingsInfoRow(
                        symbol: "exclamationmark.triangle.fill",
                        color: .orange,
                        title: "Codec Availability",
                        detail: message
                    )
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Codec & Compression")
        .navigationBarTitleDisplayMode(.large)
        .tint(.blue)
    }

    private var availableCodecs: [String] {
        camera.capabilitySnapshot.availableVideoCodecs
    }

    private var codecBinding: Binding<String> {
        Binding(
            get: { camera.selectedVideoCodec },
            set: { codec in
                guard availableCodecs.contains(codec) else { return }
                camera.selectedVideoCodec = codec
            }
        )
    }

    private var compressionBinding: Binding<String> {
        Binding(
            get: { camera.videoCompression.rawValue },
            set: { rawValue in
                guard let compression = VideoCompression(rawValue: rawValue) else { return }
                camera.videoCompression = compression
            }
        )
    }

    private var codecControlsEnabled: Bool {
        !camera.isRecording &&
        !camera.isRecordingStarting &&
        !camera.isFinalizingRecording &&
        !camera.isCapturingPhoto &&
        !camera.isLensTransitioning
    }
}

struct AboutSettingsView: View {
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    private var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    SettingsListIcon(symbol: "camera.fill", color: .blue)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("LowPolyCam")
                            .font(.headline)
                        Text("Camera app")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            Section("APP") {
                HStack {
                    Text("Version")
                    Spacer()
                    Text(version).foregroundStyle(.secondary)
                }
                HStack {
                    Text("Build")
                    Spacer()
                    Text(build).foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.large)
        .tint(.blue)
    }
}

private struct VideoFormatOption: Identifiable {
    let resolution: VideoResolution
    let frameRate: VideoFrameRate
    var id: String { "\(resolution.rawValue)-\(frameRate.rawValue)" }
}

private struct SlowMotionFormatOption: Identifiable {
    let resolution: VideoResolution
    let frameRate: CameraManager.SlowMotionFrameRate
    var id: String { "\(resolution.rawValue)-\(frameRate.rawValue)" }
}
