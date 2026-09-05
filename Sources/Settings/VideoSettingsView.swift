import SwiftUI

struct VideoSettingsView: View {
    @ObservedObject var camera: CameraManager
    @Environment(\.dismiss) private var dismiss
    @AppStorage("cameraGridEnabled") private var isGridEnabled = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    modeHeader

                    switch camera.captureMode {
                    case .video:
                        videoSettings
                    case .sloMo:
                        slowMotionSettings
                    case .photo:
                        photoSettings
                    }

                    SettingsCard(title: "Viewfinder", symbol: "viewfinder") {
                        SettingsToggleRow(
                            title: "Grid",
                            subtitle: "Show a 3×3 composition grid",
                            isOn: $isGridEnabled
                        )
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .background(Color(uiColor: .systemGroupedBackground))
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
                .background(.yellow.opacity(0.16), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .foregroundStyle(.yellow)

            VStack(alignment: .leading, spacing: 2) {
                Text(camera.captureMode.rawValue)
                    .font(.headline)
                Text("Only settings available for this mode and camera are shown.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    @ViewBuilder
    private var videoSettings: some View {
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

        SettingsCard(title: "Recording", symbol: "record.circle") {
            SettingsToggleRow(
                title: "Stabilization",
                subtitle: "Use automatic video stabilization when supported",
                isOn: Binding(
                    get: { camera.isVideoStabilizationEnabled },
                    set: { camera.setVideoStabilizationEnabled($0) }
                )
            )
        }
    }

    @ViewBuilder
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
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Photo Quality")
                        .font(.subheadline.weight(.semibold))
                    Text("Uses the maximum resolution supported by the active camera")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("MAX")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.yellow)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.yellow.opacity(0.13), in: Capsule())
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

private struct SettingsCard<Content: View>: View {
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

private struct SettingsDivider: View {
    var body: some View {
        Divider().opacity(0.55)
    }
}

private struct SettingsToggleRow: View {
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
        .tint(.yellow)
    }
}

private struct SettingsPickerRow<Option: Identifiable & Equatable>: View {
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
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .background(
                                selection == option ? Color.yellow : Color.primary.opacity(0.07),
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
