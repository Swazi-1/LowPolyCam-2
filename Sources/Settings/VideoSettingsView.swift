import SwiftUI

struct VideoSettingsView: View {
  @Environment(\.cameraTint) private var theme
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @ObservedObject var camera: CameraManager
  var positionStats: () -> Void = {}
  @AppStorage("photoAspect") private var photoAspect = "4:3"
  @AppStorage("settingsInterfaceStyle") private var interfaceStyle = SettingsInterfaceStyle.system
    .rawValue
  @Environment(\.dismiss) private var dismiss
  private var accent = CameraAccent()

  private var qualityColumns: [GridItem] {
    if dynamicTypeSize.isAccessibilitySize {
      return [GridItem(.flexible())]
    }
    return [
      GridItem(.flexible(), spacing: 12),
      GridItem(.flexible(), spacing: 12),
    ]
  }

  var body: some View {
    SettingsNavigationContainer {
      SettingsPage {
        mainHeader
        modeSummaryCard
        appearanceQuickControl

        switch camera.captureMode {
        case .video:
          videoQualitySettings
        case .sloMo:
          slowMotionSettings
        case .photo:
          photoSettings
        }

        SettingsSectionHeader(title: "Quick Controls")
        QuickCameraSettings(camera: camera)

        SettingsSectionHeader(title: "More Settings")
        moreSettings

        if camera.recoverableRecordingCount > 0 {
          SettingsSectionHeader(title: "Recovery")
          recoveryCard
        }
      }
      .toolbar {
        ToolbarItem(placement: .navigationBarTrailing) {
          Button("Done") { dismiss() }
            .font(.body.weight(.semibold))
        }
      }
      .navigationBarTitleDisplayMode(.inline)
    }
    .onChange(of: photoAspect) { _ in
      camera.refreshPhotoResolutionForCurrentAspect()
    }
  }

  private var mainHeader: some View {
    HStack(alignment: .firstTextBaseline) {
      Text("Settings")
        .font(.system(size: 36, weight: .bold, design: .rounded))
      Spacer()
      Text("LowPolyCam")
        .font(.subheadline.weight(.medium))
        .foregroundStyle(theme.opacity(0.7))
    }
    .padding(.horizontal, 4)
    .padding(.top, 2)
  }

  private var modeSummaryCard: some View {
    HStack(spacing: 13) {
      Image(systemName: modeSymbol)
        .font(.system(size: 21, weight: .semibold))
        .foregroundStyle(accent.foregroundColor)
        .frame(width: 48, height: 48)
        .background(theme, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

      VStack(alignment: .leading, spacing: 3) {
        Text(
          "\(camera.captureMode.rawValue) • \(camera.cameraPosition == .back ? "Rear" : "Front")"
        )
        .font(.headline)
        Text(qualitySummary)
          .font(.subheadline)
          .foregroundStyle(theme.opacity(0.62))
          .lineLimit(2)
          .minimumScaleFactor(0.82)
      }
      Spacer(minLength: 8)
    }
    .padding(15)
    .background(
      Color(uiColor: .secondarySystemGroupedBackground).opacity(0.97),
      in: RoundedRectangle(cornerRadius: 20, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 20, style: .continuous)
        .stroke(.primary.opacity(0.05), lineWidth: 1)
        .allowsHitTesting(false)
    }
  }

  private var appearanceQuickControl: some View {
    SettingsCard {
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 12) {
          appearanceLabel
          Spacer(minLength: 4)
          appearanceSegments
        }

        VStack(alignment: .leading, spacing: 12) {
          appearanceLabel
          appearanceSegments
            .frame(maxWidth: .infinity)
        }
      }
    }
  }

  private var appearanceLabel: some View {
    HStack(spacing: 12) {
      SettingsSymbolBox(symbol: "sun.max")
      VStack(alignment: .leading, spacing: 3) {
        Text("Appearance")
          .font(.subheadline.weight(.medium))
        Text("App theme")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  private var appearanceSegments: some View {
    HStack(spacing: 3) {
      ForEach(SettingsInterfaceStyle.allCases) { style in
        Button {
          guard interfaceStyle != style.rawValue else { return }
          interfaceStyle = style.rawValue
        } label: {
          VStack(spacing: 3) {
            Image(systemName: style.symbol)
              .font(.system(size: 13, weight: .semibold))
            Text(style.rawValue)
              .font(.caption2.weight(.medium))
              .lineLimit(1)
          }
          .foregroundStyle(
            interfaceStyle == style.rawValue ? accent.foregroundColor : Color.secondary
          )
          .frame(maxWidth: .infinity, minHeight: 50)
          .padding(.horizontal, 4)
          .background(
            interfaceStyle == style.rawValue ? theme : Color.clear,
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
          )
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(interfaceStyle == style.rawValue ? .isSelected : [])
      }
    }
    .padding(4)
    .frame(minWidth: 180)
    .background(
      Color.primary.opacity(0.045),
      in: RoundedRectangle(cornerRadius: 14, style: .continuous)
    )
  }

  private var videoQualitySettings: some View {
    Group {
      SettingsSectionHeader(title: "Video Settings")
      LazyVGrid(columns: qualityColumns, spacing: 12) {
        SettingsOptionCard(
          title: "Resolution",
          subtitle: "Video size",
          symbol: "rectangle.inset.filled",
          selection: videoResolutionBinding,
          options: camera.supportedResolutions.map { ($0, $0.rawValue) }
        )

        SettingsOptionCard(
          title: "Frame Rate",
          subtitle: "Frames per second",
          symbol: "speedometer",
          selection: videoFrameRateBinding,
          options: camera.supportedFrameRates.map { ($0, $0.label) }
        )

        SettingsOptionCard(
          title: "Compression",
          subtitle: "File size vs quality",
          symbol: "externaldrive.fill",
          selection: Binding(
            get: { camera.videoCompression },
            set: { if $0 != camera.videoCompression { camera.videoCompression = $0 } }
          ),
          options: VideoCompression.allCases.map { ($0, $0.rawValue) }
        )

        SettingsOptionCard(
          title: "Codec",
          subtitle: "Video encoding format",
          symbol: "doc.fill",
          selection: Binding(
            get: { camera.selectedVideoCodec },
            set: { if $0 != camera.selectedVideoCodec { camera.selectedVideoCodec = $0 } }
          ),
          options: [("H264", "H.264"), ("HEVC", "HEVC")]
        )
      }

      if let message = camera.codecAvailabilityMessage {
        Text(message)
          .font(.caption)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 4)
      }
    }
  }

  private var slowMotionSettings: some View {
    Group {
      SettingsSectionHeader(title: "Slo-Mo Settings")

      if camera.supportedSlowMotionResolutions.isEmpty {
        SettingsCard {
          HStack(spacing: 12) {
            SettingsSymbolBox(symbol: "slowmo")
            Text("Slo-Mo isn’t available on this camera.")
              .font(.subheadline)
              .foregroundStyle(.secondary)
          }
        }
      } else {
        LazyVGrid(columns: qualityColumns, spacing: 12) {
          SettingsOptionCard(
            title: "Resolution",
            subtitle: "Slo-Mo size",
            symbol: "rectangle.inset.filled",
            selection: slowMotionResolutionBinding,
            options: camera.supportedSlowMotionResolutions.map { ($0, $0.rawValue) }
          )

          SettingsOptionCard(
            title: "Frame Rate",
            subtitle: "Frames per second",
            symbol: "speedometer",
            selection: slowMotionFrameRateBinding,
            options: camera.supportedSlowMotionFrameRates.map { ($0, $0.label) }
          )

          SettingsOptionCard(
            title: "Compression",
            subtitle: "File size vs quality",
            symbol: "externaldrive.fill",
            selection: Binding(
              get: { camera.videoCompression },
              set: { if $0 != camera.videoCompression { camera.videoCompression = $0 } }
            ),
            options: VideoCompression.allCases.map { ($0, $0.rawValue) }
          )

          SettingsOptionCard(
            title: "Codec",
            subtitle: "Video encoding format",
            symbol: "doc.fill",
            selection: Binding(
              get: { camera.selectedVideoCodec },
              set: { if $0 != camera.selectedVideoCodec { camera.selectedVideoCodec = $0 } }
            ),
            options: [("H264", "H.264"), ("HEVC", "HEVC")]
          )
        }

        if camera.cameraPosition == .back && camera.minimumZoomFactor >= 1 {
          Text(
            "0.5× is shown only when Ultra Wide supports the selected resolution and Slo-Mo frame rate."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 4)
        }

        if let message = camera.codecAvailabilityMessage {
          Text(message)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
        }
      }
    }
  }

  private var photoSettings: some View {
    Group {
      SettingsSectionHeader(title: "Photo Settings")
      PhotoResolutionCard(camera: camera)

      LazyVGrid(columns: qualityColumns, spacing: 12) {
        SettingsOptionCard(
          title: "Aspect",
          subtitle: "Photo shape",
          symbol: "aspectratio.fill",
          selection: $photoAspect,
          options: [("4:3", "4:3"), ("1:1", "1:1")]
        )

        SettingsOptionCard(
          title: "Format",
          subtitle: "Image file format",
          symbol: "photo.fill",
          selection: Binding(
            get: { camera.photoFileFormat },
            set: { if $0 != camera.photoFileFormat { camera.photoFileFormat = $0 } }
          ),
          options: [("HEIC", "HEIC"), ("JPEG", "JPEG")]
        )
      }
    }
  }

  @ViewBuilder
  private var moreSettings: some View {
    switch camera.captureMode {
    case .video:
      LazyVGrid(columns: qualityColumns, spacing: 12) {
        NavigationLink {
          VideoPresetsView(camera: camera)
        } label: {
          SettingsNavigationTile(
            title: "Video Presets", subtitle: "Save favorite setups", symbol: "square.3.layers.3d")
        }
        .buttonStyle(.plain)

        NavigationLink {
          CapturePreferencesView(camera: camera)
        } label: {
          SettingsNavigationTile(
            title: "Capture", subtitle: "Timer, zoom, haptics", symbol: "camera")
        }
        .buttonStyle(.plain)

        NavigationLink {
          ViewfinderHUDSettingsView(camera: camera)
        } label: {
          SettingsNavigationTile(
            title: "Viewfinder & HUD", subtitle: "On-screen tools", symbol: "viewfinder")
        }
        .buttonStyle(.plain)

        NavigationLink {
          AdvancedRecordingSettingsView(camera: camera, positionStats: positionStats)
        } label: {
          SettingsNavigationTile(
            title: "Advanced Recording", subtitle: "Pro options and diagnostics",
            symbol: "waveform.path.ecg")
        }
        .buttonStyle(.plain)
      }

    case .sloMo:
      HStack(alignment: .top, spacing: 12) {
        NavigationLink {
          CapturePreferencesView(camera: camera)
        } label: {
          SettingsNavigationTile(
            title: "Capture", subtitle: "Timer, zoom, haptics", symbol: "camera")
        }
        .buttonStyle(.plain)

        NavigationLink {
          ViewfinderHUDSettingsView(camera: camera)
        } label: {
          SettingsNavigationTile(
            title: "Viewfinder & HUD", subtitle: "On-screen tools", symbol: "viewfinder")
        }
        .buttonStyle(.plain)
      }
      NavigationLink {
        AdvancedRecordingSettingsView(camera: camera, positionStats: positionStats)
      } label: {
        SettingsNavigationTile(
          title: "Advanced Recording", subtitle: "Long sessions and diagnostics",
          symbol: "waveform.path.ecg", fullWidth: true)
      }
      .buttonStyle(.plain)

    case .photo:
      HStack(alignment: .top, spacing: 12) {
        NavigationLink {
          CapturePreferencesView(camera: camera)
        } label: {
          SettingsNavigationTile(
            title: "Capture", subtitle: "Timer, shutter, haptics", symbol: "camera")
        }
        .buttonStyle(.plain)

        NavigationLink {
          ViewfinderHUDSettingsView(camera: camera)
        } label: {
          SettingsNavigationTile(
            title: "Viewfinder & HUD", subtitle: "On-screen tools", symbol: "viewfinder")
        }
        .buttonStyle(.plain)
      }
    }

    NavigationLink {
      AppearanceSettingsView()
    } label: {
      SettingsNavigationTile(
        title: "Appearance", subtitle: "Colors, interface and theme", symbol: "sun.max",
        fullWidth: true)
    }
    .buttonStyle(.plain)
  }

  private var recoveryCard: some View {
    SettingsCard {
      HStack(spacing: 12) {
        SettingsSymbolBox(symbol: "arrow.clockwise.circle.fill")
        VStack(alignment: .leading, spacing: 3) {
          Text(
            "\(camera.recoverableRecordingCount) recording\(camera.recoverableRecordingCount == 1 ? "" : "s") waiting"
          )
          .font(.subheadline.weight(.semibold))
          Text("Photos couldn’t import these recordings earlier.")
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

  private var qualitySummary: String {
    switch camera.captureMode {
    case .video:
      return
        "\(camera.selectedResolution.rawValue) • \(camera.selectedFrameRate.label) • \(camera.selectedVideoCodec) • \(camera.videoCompression.rawValue)"
    case .sloMo:
      return
        "\(camera.selectedSlowMotionResolution.rawValue) • \(camera.selectedSlowMotionFrameRate.label) • \(camera.selectedVideoCodec) • \(camera.videoCompression.rawValue)"
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

  private var videoResolutionBinding: Binding<VideoResolution> {
    Binding(
      get: { camera.selectedResolution },
      set: { value in
        guard value != camera.selectedResolution else { return }
        camera.selectResolution(value)
      }
    )
  }

  private var videoFrameRateBinding: Binding<VideoFrameRate> {
    Binding(
      get: { camera.selectedFrameRate },
      set: { value in
        guard value != camera.selectedFrameRate else { return }
        camera.selectFrameRate(value)
      }
    )
  }

  private var slowMotionResolutionBinding: Binding<VideoResolution> {
    Binding(
      get: { camera.selectedSlowMotionResolution },
      set: { value in
        guard value != camera.selectedSlowMotionResolution else { return }
        camera.selectSlowMotionResolution(value)
      }
    )
  }

  private var slowMotionFrameRateBinding: Binding<CameraManager.SlowMotionFrameRate> {
    Binding(
      get: { camera.selectedSlowMotionFrameRate },
      set: { value in
        guard value != camera.selectedSlowMotionFrameRate else { return }
        camera.selectSlowMotionFrameRate(value)
      }
    )
  }
}

private struct PhotoResolutionCard: View {
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
    SettingsCard {
      HStack(spacing: 12) {
        SettingsSymbolBox(symbol: "camera.aperture")
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
                .font(.system(size: 9, weight: .bold))
            }
            .foregroundStyle(theme)
            .padding(.horizontal, 12)
            .frame(minHeight: 42)
            .background(theme.opacity(0.11), in: Capsule())
            .contentShape(Rectangle())
          }
        }
      }
    }
  }
}
