import SwiftUI

/// Main settings hub. It intentionally uses native SwiftUI List/Section controls so it follows
/// the system Settings visual language instead of duplicating LowPolyCam's camera HUD styling.
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
                if matches("Camera Setup capture mode video photo slo-mo rear front") {
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
                }

                if matches("Appearance light dark system colors theme") {
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
                }

                if captureSectionVisible {
                    Section("CAPTURE") {
                        if matches("Record Video resolution frame rate fps stabilization") {
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
                        }

                        if matches("Record Slo-Mo slow motion resolution frame rate fps") {
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
                        }

                        if matches("Photo Capture megapixels MP HEIC JPEG aspect burst flash") {
                            NavigationLink {
                                PhotoCaptureSettingsView(camera: camera)
                            } label: {
                                SettingsNavigationLabel(
                                    symbol: "camera.fill",
                                    color: .green,
                                    title: "Photo Capture",
                                    value: "\(camera.currentPhotoResolutionLabel) • \(camera.photoFileFormat)"
                                )
                            }
                        }

                        if matches("Codec Compression HEVC H.264 H264 quality data saver medium high") {
                            NavigationLink {
                                CodecCompressionSettingsView(camera: camera)
                            } label: {
                                SettingsNavigationLabel(
                                    symbol: "internaldrive.fill",
                                    color: .blue,
                                    title: "Codec & Compression",
                                    value: "\(codecName) • \(camera.videoCompression.rawValue)"
                                )
                            }
                        }
                    }
                }

                if controlsSectionVisible {
                    Section("CONTROLS") {
                        if matches("Quick Controls stabilization grid level opacity") {
                            NavigationLink {
                                QuickControlsSettingsView(camera: camera)
                            } label: {
                                SettingsNavigationLabel(
                                    symbol: "slider.horizontal.3",
                                    color: .gray,
                                    title: "Quick Controls"
                                )
                            }
                        }

                        if matches("Capture Preferences shutter timer haptics zoom recording lock mirror selfie camera controls") {
                            NavigationLink {
                                CapturePreferencesView(camera: camera)
                            } label: {
                                SettingsNavigationLabel(
                                    symbol: "gearshape.fill",
                                    color: .purple,
                                    title: "Capture Preferences"
                                )
                            }
                        }

                        if matches("Viewfinder HUD on-screen display battery storage thermal remaining") {
                            NavigationLink {
                                ViewfinderHUDSettingsView(camera: camera)
                            } label: {
                                SettingsNavigationLabel(
                                    symbol: "rectangle.inset.filled",
                                    color: .blue,
                                    title: "Viewfinder & HUD"
                                )
                            }
                        }

                        if matches("Advanced Recording recovery split longevity live stats storage protection") {
                            NavigationLink {
                                AdvancedRecordingSettingsView(camera: camera, positionStats: positionStats)
                            } label: {
                                SettingsNavigationLabel(
                                    symbol: "waveform.path.ecg",
                                    color: .purple,
                                    title: "Advanced Recording"
                                )
                            }
                        }

                        if matches("Video Presets balanced high quality all rounder all day social") {
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
                    }
                }

                if appSectionVisible {
                    Section("APP") {
                        if matches("Diagnostics logs logging bug report") {
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
                        }

                        if matches("About version build LowPolyCam") {
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
                }
            }
            .listStyle(.insetGrouped)
            .listSectionSpacing(18)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search")
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

    private func matches(_ keywords: String) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || keywords.localizedCaseInsensitiveContains(query)
    }

    private var captureSectionVisible: Bool {
        matches("Record Video resolution frame rate fps stabilization") ||
        matches("Record Slo-Mo slow motion resolution frame rate fps") ||
        matches("Photo Capture megapixels MP HEIC JPEG aspect burst flash") ||
        matches("Codec Compression HEVC H.264 H264 quality data saver medium high")
    }

    private var controlsSectionVisible: Bool {
        matches("Quick Controls stabilization grid level opacity") ||
        matches("Capture Preferences shutter timer haptics zoom recording lock mirror selfie camera controls") ||
        matches("Viewfinder HUD on-screen display battery storage thermal remaining") ||
        matches("Advanced Recording recovery split longevity live stats storage protection") ||
        matches("Video Presets balanced high quality all rounder all day social")
    }

    private var appSectionVisible: Bool {
        matches("Diagnostics logs logging bug report") || matches("About version build LowPolyCam")
    }

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
            return "\(camera.selectedResolution.rawValue) • \(camera.selectedFrameRate.rawValue) fps • \(codecName)"
        case .sloMo:
            return "\(camera.selectedSlowMotionResolution.rawValue) • \(camera.selectedSlowMotionFrameRate.rawValue) fps • HEVC"
        case .photo:
            return "\(camera.currentPhotoResolutionLabel) • \(camera.photoFileFormat)"
        }
    }

    private var videoSummary: String {
        resolutionSummary(camera.selectedResolution, fps: camera.selectedFrameRate.rawValue)
    }

    private var slowMotionSummary: String {
        resolutionSummary(camera.selectedSlowMotionResolution, fps: camera.selectedSlowMotionFrameRate.rawValue)
    }

    private func resolutionSummary(_ resolution: VideoResolution, fps: Int) -> String {
        switch resolution {
        case .p4k: return "4K at \(fps) fps"
        case .p1080: return "1080p HD at \(fps) fps"
        case .p720: return "720p HD at \(fps) fps"
        }
    }
}
