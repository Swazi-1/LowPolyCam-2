import SwiftUI

struct LiveStatsOverlay: View {
  @ObservedObject var camera: CameraManager
  var editing: Bool
  var finish: () -> Void
  @AppStorage("liveStatsX") private var x = 0.5
  @AppStorage("liveStatsY") private var y = 0.28
  @AppStorage("liveStatsSize") private var size = "Normal"
  @AppStorage("liveStatsShowFPS") private var showFPS = true
  @AppStorage("liveStatsShowBitrate") private var showBitrate = true
  @AppStorage("liveStatsShowDrops") private var showDrops = true
  @State private var dragOrigin: CGPoint?
  @Environment(\.cameraTint) private var theme

  var body: some View {
    GeometryReader { proxy in
      let compact = size == "Compact"
      let width = min(CGFloat(compact ? 176 : 238), max(120, proxy.size.width - 24))
      let rows = max(1, [showFPS, showBitrate, showDrops].filter { $0 }.count)
      let height = CGFloat(rows * (compact ? 20 : 22) + (compact ? 16 : 24) + (!compact ? 20 : 0))
      let travelX = max(1, proxy.size.width - width - 24)
      let travelY = max(1, proxy.size.height - height - 24)
      VStack(alignment: .leading, spacing: 6) {
        if !compact {
          Text(editing ? "DRAG TO POSITION" : "LIVE RECORDING").font(.caption2.bold())
            .foregroundStyle(theme)
        }
        if showFPS {
          metric(
            compact ? "FPS" : "Capture FPS",
            camera.liveFPS.map { String(format: "%.1f", $0) } ?? "—")
        }
        if showBitrate {
          metric(
            compact ? "Bitrate" : "File bitrate",
            camera.liveMbps.map { String(format: "%.1f Mbps", $0) } ?? "—")
        }
        if showDrops {
          metric(
            compact ? "Drops*" : "Capture drops", camera.liveCaptureDrops.map { String($0) } ?? "—")
        }
        if !showFPS && !showBitrate && !showDrops { Text("No stats selected").font(.caption) }
      }
      .font(.system(size: 12, weight: .medium, design: .monospaced))
      .foregroundStyle(.white)
      .padding(compact ? 8 : 12)
      .frame(width: width, height: height)
      .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 16))
      .overlay(RoundedRectangle(cornerRadius: 16).stroke(theme.opacity(0.65)))
      .position(
        x: 12 + width / 2 + CGFloat(min(max(x, 0), 1)) * travelX,
        y: 12 + height / 2 + CGFloat(min(max(y, 0), 1)) * travelY
      )
      .gesture(
        DragGesture().onChanged { value in
          guard editing else { return }
          if dragOrigin == nil { dragOrigin = CGPoint(x: x, y: y) }
          guard let origin = dragOrigin else { return }
          x = min(max(Double(origin.x + value.translation.width / travelX), 0), 1)
          y = min(max(Double(origin.y + value.translation.height / travelY), 0), 1)
        }.onEnded { _ in dragOrigin = nil }
      )
      .allowsHitTesting(editing)

      if editing {
        VStack {
          HStack {
            Button("Reset") {
              DiagnosticLogger.shared.action("HUD position reset pressed")
              x = 0.5
              y = 0.28
            }
            Spacer()
            Button("Done") {
              DiagnosticLogger.shared.action("HUD position editor done pressed")
              finish()
            }.font(.body.weight(.bold))
          }
          .padding().background(.black.opacity(0.85), in: Capsule())
          Spacer()
        }.padding(12).tint(theme)
      }
    }
    .dynamicTypeSize(.medium ... .large)
  }

  private func metric(_ title: String, _ value: String) -> some View {
    HStack {
      Text(title)
      Spacer(minLength: 6)
      Text(value).monospacedDigit()
    }
    .lineLimit(1).minimumScaleFactor(0.75)
  }
}

struct AdvancedRecordingSettingsView: View {
  @ObservedObject var camera: CameraManager
  var positionStats: () -> Void
  @AppStorage("splitMinutes") private var splitMinutes = 0
  @AppStorage("longevityMode") private var longevity = false
  @AppStorage("liveRecordingStats") private var stats = false
  @AppStorage("lowStorageWarning") private var lowStorageWarning = true

  var body: some View {
    SettingsPage {
      SettingsSectionHeader(title: "Long Sessions")
      SettingsCard {
        SettingsMenuRow(
          title: "Split Recording",
          subtitle: "Start a new file automatically during long recordings",
          symbol: "clock.arrow.circlepath",
          selection: $splitMinutes,
          options: [(0, "Off"), (15, "15 min"), (30, "30 min"), (60, "1 hour"), (120, "2 hours")]
        )

        if camera.captureMode == .video {
          SettingsDivider()
          SettingsToggleRow(
            title: "Longevity Mode",
            subtitle:
              "720p · 30 fps · HEVC · Data Saver and lower screen brightness while recording",
            isOn: Binding(
              get: { longevity },
              set: { enabled in
                guard enabled != longevity else { return }
                camera.applyLongevityMode(enabled)
              }
            ),
            symbol: "leaf.fill"
          )
        }

        SettingsDivider()
        SettingsToggleRow(
          title: "Low Storage Warning",
          subtitle: "Warn when free storage falls below 1 GB",
          isOn: $lowStorageWarning,
          symbol: "externaldrive.badge.exclamationmark"
        )
      }

      SettingsSectionHeader(title: "Diagnostics")
      SettingsCard {
        SettingsToggleRow(
          title: "Live Recording Stats",
          subtitle: camera.captureMode == .sloMo
            ? "File bitrate stays available. Extra FPS/drop monitoring stays off at 120/240 fps for stability."
            : "Measured capture FPS, file bitrate and monitoring-output drops",
          isOn: $stats,
          symbol: "chart.bar.xaxis"
        )
        SettingsDivider()
        NavigationLink {
          LiveStatsSettings(positionStats: positionStats)
        } label: {
          SettingsNavigationRow(
            title: "Live Stats Settings",
            subtitle: "Size, information and position",
            symbol: "slider.horizontal.3"
          )
        }
        .buttonStyle(.plain)
        SettingsDivider()
        ShareLink(item: DiagnosticLogger.shared.currentLogFileURL) {
          SettingsNavigationRow(
            title: "Export Diagnostic Log",
            subtitle: "Share or save the current log to Files",
            symbol: "square.and.arrow.up"
          )
        }
        .simultaneousGesture(TapGesture().onEnded {
          DiagnosticLogger.shared.action("Export Diagnostic Log pressed")
          DiagnosticLogger.shared.flush()
        })
        .buttonStyle(.plain)
      }
    }
    .navigationTitle("Advanced Recording")
    .navigationBarTitleDisplayMode(.inline)
    .onChange(of: stats) { _ in camera.refreshLiveMetrics() }
  }
}

struct LiveStatsSettings: View {
  var positionStats: () -> Void
  @AppStorage("liveStatsSize") private var size = "Normal"
  @AppStorage("liveStatsShowFPS") private var showFPS = true
  @AppStorage("liveStatsShowBitrate") private var showBitrate = true
  @AppStorage("liveStatsShowDrops") private var showDrops = true

  var body: some View {
    SettingsPage {
      SettingsSectionHeader(title: "Panel")
      SettingsCard {
        SettingsChoiceRow(
          title: "Panel Size",
          subtitle: "Choose how much screen space Live Stats uses",
          symbol: "textformat.size",
          selection: $size,
          options: [("Compact", "Compact"), ("Normal", "Normal")]
        )
      }

      SettingsSectionHeader(title: "Information")
      SettingsCard {
        SettingsToggleRow(
          title: "Capture FPS",
          subtitle: "Measured frames arriving from the camera",
          isOn: $showFPS,
          symbol: "speedometer"
        )
        SettingsDivider()
        SettingsToggleRow(
          title: "File Bitrate",
          subtitle: "Measured recording data in Mbps",
          isOn: $showBitrate,
          symbol: "arrow.up.arrow.down"
        )
        SettingsDivider()
        SettingsToggleRow(
          title: "Capture Drops",
          subtitle: "Frames dropped by the monitoring output; not encoder drops",
          isOn: $showDrops,
          symbol: "exclamationmark.triangle"
        )
      }

      SettingsSectionHeader(title: "Position")
      SettingsCard {
        SettingsActionRow(
          title: "Position Live Stats",
          subtitle: "Drag the panel directly on the camera screen",
          symbol: "arrow.up.and.down.and.arrow.left.and.right"
        ) {
          positionStats()
        }
      }
    }
    .navigationTitle("Live Stats")
    .navigationBarTitleDisplayMode(.inline)
  }
}
