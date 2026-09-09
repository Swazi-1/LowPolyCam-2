import SwiftUI

struct CameraSetupSettingsView: View {
    @ObservedObject var camera: CameraManager
    @AppStorage("rememberCaptureMode") private var rememberCaptureMode = false
    @AppStorage("appColorScheme") private var appColorScheme = "system"

    var body: some View {
        List {
            Section("CAPTURE MODE") {
                ForEach(CameraManager.CaptureMode.allCases) { mode in
                    Button {
                        camera.selectCaptureMode(mode)
                    } label: {
                        SettingsCheckmarkRow(
                            title: displayName(for: mode),
                            selected: camera.captureMode == mode,
                            enabled: camera.isCaptureModeSupported(mode)
                        )
                    }
                    .disabled(!camera.isCaptureModeSupported(mode) || !cameraControlsEnabled)
                }
            }

            Section("CAMERA") {
                cameraPositionButton(.back, title: "Rear Camera")
                cameraPositionButton(.front, title: "Front Camera")
            }

            Section("PREFERENCES") {
                Toggle(isOn: $rememberCaptureMode) {
                    SettingsToggleLabel(
                        symbol: "arrow.counterclockwise.circle.fill",
                        color: .green,
                        title: "Remember Camera Mode",
                        subtitle: "Open LowPolyCam in the last used capture mode."
                    )
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Camera Setup")
        .navigationBarTitleDisplayMode(.large)
        .tint(.blue)
        .preferredColorScheme(resolvedColorScheme(appColorScheme))
    }

    @ViewBuilder
    private func cameraPositionButton(_ position: CameraManager.CameraPosition, title: String) -> some View {
        Button {
            guard camera.cameraPosition != position else { return }
            camera.switchCamera()
        } label: {
            SettingsCheckmarkRow(
                title: title,
                selected: camera.cameraPosition == position,
                enabled: cameraControlsEnabled
            )
        }
        .disabled(!cameraControlsEnabled)
    }

    private var cameraControlsEnabled: Bool {
        !camera.isRecording &&
        !camera.isRecordingStarting &&
        !camera.isFinalizingRecording &&
        !camera.isCapturingPhoto &&
        !camera.isPreviewTransitioning &&
        !camera.isLensTransitioning
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
    @AppStorage("appColorScheme") private var appColorScheme = "system"

    private var formatOptions: [VideoFormatOption] {
        camera.supportedVideoFormatPairs().map {
            VideoFormatOption(resolution: $0.0, frameRate: $0.1)
        }
    }

    var body: some View {
        List {
            Section("VIDEO QUALITY") {
                ForEach(formatOptions) { option in
                    Button {
                        camera.selectVideoFormat(resolution: option.resolution, frameRate: option.frameRate)
                    } label: {
                        SettingsCheckmarkRow(
                            title: formatName(option.resolution, option.frameRate),
                            selected: camera.selectedResolution == option.resolution && camera.selectedFrameRate == option.frameRate,
                            enabled: formatControlsEnabled
                        )
                    }
                    .disabled(!formatControlsEnabled)
                }
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
                        title: "Codec",
                        value: camera.selectedVideoCodec == "HEVC" ? "HEVC" : "H.264"
                    )
                }

                NavigationLink {
                    CodecCompressionSettingsView(camera: camera)
                } label: {
                    SettingsNavigationLabel(
                        symbol: "square.stack.3d.up.fill",
                        color: .purple,
                        title: "Compression",
                        value: camera.videoCompression.rawValue
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
        .preferredColorScheme(resolvedColorScheme(appColorScheme))
    }

    private var formatControlsEnabled: Bool {
        !camera.isRecording &&
        !camera.isRecordingStarting &&
        !camera.isFinalizingRecording &&
        !camera.isLensTransitioning &&
        !camera.isPreviewTransitioning
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
    @AppStorage("appColorScheme") private var appColorScheme = "system"

    private var formatOptions: [SlowMotionFormatOption] {
        camera.supportedSlowMotionFormatPairs().map {
            SlowMotionFormatOption(resolution: $0.0, frameRate: $0.1)
        }
    }

    var body: some View {
        List {
            Section("SLO-MO QUALITY") {
                if formatOptions.isEmpty {
                    Text("Slo-Mo isn’t available on this camera.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(formatOptions) { option in
                        Button {
                            camera.selectSlowMotionFormat(resolution: option.resolution, frameRate: option.frameRate)
                        } label: {
                            SettingsCheckmarkRow(
                                title: formatName(option.resolution, option.frameRate),
                                selected: camera.selectedSlowMotionResolution == option.resolution && camera.selectedSlowMotionFrameRate == option.frameRate,
                                enabled: formatControlsEnabled
                            )
                        }
                        .disabled(!formatControlsEnabled)
                    }
                }
            } footer: {
                Text("Slo-Mo uses HEVC automatically. Available resolutions and frame rates depend on the selected camera and lens.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Record Slo-Mo")
        .navigationBarTitleDisplayMode(.large)
        .tint(.blue)
        .preferredColorScheme(resolvedColorScheme(appColorScheme))
    }

    private var formatControlsEnabled: Bool {
        !camera.isRecording &&
        !camera.isRecordingStarting &&
        !camera.isFinalizingRecording &&
        !camera.isLensTransitioning &&
        !camera.isPreviewTransitioning
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
    @AppStorage("burstCount") private var burstCount = 5
    @AppStorage("appColorScheme") private var appColorScheme = "system"

    var body: some View {
        List {
            Section("PHOTO QUALITY") {
                ForEach(camera.supportedPhotoMegapixels, id: \.self) { megapixels in
                    Button {
                        camera.selectPhotoMegapixels(megapixels)
                    } label: {
                        SettingsCheckmarkRow(
                            title: "\(megapixels) MP",
                            selected: camera.selectedPhotoMegapixels == megapixels
                        )
                    }
                }
            } footer: {
                Text("LowPolyCam keeps full sensor quality and saves at the selected megapixel count.")
            }

            Section("FORMAT") {
                ForEach(["HEIC", "JPEG"], id: \.self) { format in
                    Button {
                        camera.photoFileFormat = format
                    } label: {
                        SettingsCheckmarkRow(
                            title: format,
                            subtitle: format == "HEIC" ? "Smaller files with high quality" : "Wider compatibility",
                            selected: camera.photoFileFormat == format
                        )
                    }
                }
            }

            Section("ASPECT RATIO") {
                ForEach(["4:3", "1:1"], id: \.self) { aspect in
                    Button {
                        guard photoAspect != aspect else { return }
                        photoAspect = aspect
                        camera.updatePhotoAspectSelection(aspect)
                    } label: {
                        SettingsCheckmarkRow(title: aspect, selected: photoAspect == aspect)
                    }
                }
            }

            Section("BURST") {
                Picker("Photos per Burst", selection: $burstCount) {
                    Text("5").tag(5)
                    Text("10").tag(10)
                    Text("15").tag(15)
                }
            } footer: {
                Text("Hold the shutter to start a burst and release it to stop early.")
            }

            Section("PHOTO FLASH") {
                ForEach(CameraManager.PhotoFlashMode.allCases) { mode in
                    Button {
                        camera.photoFlashMode = mode
                    } label: {
                        SettingsCheckmarkRow(title: mode.rawValue, selected: camera.photoFlashMode == mode)
                    }
                }
            } footer: {
                Text("Flash is applied when the selected camera supports still-photo flash.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Photo Capture")
        .navigationBarTitleDisplayMode(.large)
        .tint(.blue)
        .preferredColorScheme(resolvedColorScheme(appColorScheme))
        .onAppear { camera.updatePhotoAspectSelection(photoAspect) }
    }
}

struct CodecCompressionSettingsView: View {
    @ObservedObject var camera: CameraManager
    @AppStorage("appColorScheme") private var appColorScheme = "system"

    var body: some View {
        List {
            Section("CODEC") {
                codecRow("HEVC", title: "HEVC")
                codecRow("H264", title: "H.264")
            } footer: {
                Text("HEVC saves space efficiently and is required for some high-resolution or high-frame-rate combinations.")
            }

            Section("COMPRESSION") {
                ForEach(VideoCompression.allCases) { compression in
                    Button {
                        camera.videoCompression = compression
                    } label: {
                        SettingsCheckmarkRow(
                            title: compression.rawValue,
                            subtitle: compressionSubtitle(compression),
                            selected: camera.videoCompression == compression
                        )
                    }
                }
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
        .preferredColorScheme(resolvedColorScheme(appColorScheme))
    }

    @ViewBuilder
    private func codecRow(_ codec: String, title: String) -> some View {
        let enabled = camera.isVideoCodecSupported(codec)
        Button {
            guard enabled else { return }
            camera.selectedVideoCodec = codec
        } label: {
            SettingsCheckmarkRow(
                title: title,
                selected: camera.selectedVideoCodec == codec,
                enabled: enabled
            )
        }
        .disabled(!enabled)
    }

    private func compressionSubtitle(_ compression: VideoCompression) -> String {
        switch compression {
        case .dataSaver: return "Smallest files"
        case .medium: return "Balanced size and quality"
        case .high: return "Highest recording quality"
        }
    }
}

struct AboutSettingsView: View {
    @AppStorage("appColorScheme") private var appColorScheme = "system"

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
        .preferredColorScheme(resolvedColorScheme(appColorScheme))
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
