import SwiftUI

struct VideoPresetsView: View {
  @ObservedObject var camera: CameraManager
  @Environment(\.cameraTint) private var theme
  @Environment(\.cameraReadableTint) private var readableTheme
  @Environment(\.dismiss) private var dismiss
  @State private var preview: VideoQuickPreset = .balanced
  private var accent = CameraAccent()

  init(camera: CameraManager) {
    self.camera = camera
  }

  var body: some View {
    SettingsPage {
      SettingsSectionHeader(title: "Selected Preset")
      SettingsCard {
        HStack(spacing: 13) {
          SettingsSymbolBox(symbol: "video.fill", selected: true)
          VStack(alignment: .leading, spacing: 4) {
            Text(preview.rawValue)
              .font(.headline)
            Text(
              "\(preview.resolution.rawValue) • \(preview.frameRate.rawValue) fps • HEVC • \(preview.compression.rawValue)"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
          }
          Spacer()
        }
      }

      SettingsSectionHeader(title: "Video Presets")
      LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
        ForEach(VideoQuickPreset.allCases) { preset in
          Button {
            preview = preset
          } label: {
            VStack(alignment: .leading, spacing: 8) {
              HStack {
                Image(systemName: preview == preset ? "checkmark.circle.fill" : "circle")
                  .foregroundStyle(readableTheme)
                Spacer()
              }
              Text(preset.rawValue)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
              Text(preset.detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(3)
            }
            .padding(13)
            .frame(maxWidth: .infinity, minHeight: 122, alignment: .topLeading)
            .background(
              preview == preset
                ? theme.opacity(0.11)
                : Color(uiColor: .secondarySystemGroupedBackground).opacity(0.96),
              in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
            .overlay {
              RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(
                  preview == preset ? readableTheme.opacity(0.78) : Color.primary.opacity(0.05), lineWidth: 1
                )
                .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityAddTraits(preview == preset ? .isSelected : [])
        }
      }

      Button {
        camera.applyQuickPreset(preview) { success in
          if success { dismiss() }
        }
      } label: {
        Text("Use \(preview.rawValue)")
          .font(.subheadline.weight(.bold))
          .frame(maxWidth: .infinity, minHeight: 50)
          .foregroundStyle(accent.foregroundColor)
          .background(theme, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
      }
      .buttonStyle(.plain)
    }
    .onAppear {
      preview =
        VideoQuickPreset.allCases.first {
          $0.resolution == camera.selectedResolution && $0.frameRate == camera.selectedFrameRate
            && $0.compression == camera.videoCompression && camera.selectedVideoCodec == "HEVC"
        } ?? .balanced
    }
    .navigationTitle("Video Presets")
    .navigationBarTitleDisplayMode(.inline)
  }
}
