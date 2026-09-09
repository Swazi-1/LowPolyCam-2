import SwiftUI

struct AdvancedRecordingSettingsView: View {
    @ObservedObject var camera: CameraManager
    var positionStats: () -> Void

    @AppStorage("splitMinutes") private var splitMinutes = 0
    @AppStorage("longevityMode") private var longevity = false
    @AppStorage("liveRecordingStats") private var liveStats = false
    @AppStorage("appColorScheme") private var appColorScheme = "system"

    var body: some View {
        List {
            if camera.captureMode != .photo {
                Section("LIVE STATS") {
                    Toggle(isOn: $liveStats) {
                        SettingsToggleLabel(
                            symbol: "chart.bar.fill",
                            color: .blue,
                            title: "Live Recording Stats",
                            subtitle: "Show FPS, file bitrate and monitored frame drops."
                        )
                    }
                    .onChange(of: liveStats) { _, _ in
                        camera.refreshLiveMetrics()
                    }

                    NavigationLink {
                        LiveStatsSettings(positionStats: positionStats)
                    } label: {
                        SettingsNavigationLabel(
                            symbol: "slider.horizontal.3",
                            color: .gray,
                            title: "Live Stats Settings",
                            subtitle: liveStats ? "Size, information and position" : "Turn on Live Recording Stats to edit"
                        )
                    }
                    .disabled(!liveStats)
                }
            }

            if camera.captureMode != .photo {
                Section {
                    Picker("Split Recording", selection: $splitMinutes) {
                        Text("Off").tag(0)
                        Text("Every 15 minutes").tag(15)
                        Text("Every 30 minutes").tag(30)
                        Text("Every hour").tag(60)
                        Text("Every 2 hours").tag(120)
                    }
                } header: {
                    Text("RECORDING")
                } footer: {
                    Text("Split clips save separately with a brief gap between files.")
                }
            }

            if camera.captureMode == .video {
                Section {
                    Toggle(
                        isOn: Binding(
                            get: { longevity },
                            set: { camera.applyLongevityMode($0) }
                        )
                    ) {
                        SettingsToggleLabel(
                            symbol: "battery.100percent",
                            color: .green,
                            title: "Longevity Mode",
                            subtitle: "Uses 720p, 30 fps, HEVC and Data Saver, then dims the screen while recording."
                        )
                    }
                } header: {
                    Text("LONG RECORDINGS")
                } footer: {
                    Text("Your previous Video setup returns when Longevity Mode is turned off.")
                }
            }

            if camera.recoverableRecordingCount > 0 {
                Section("RECOVERY") {
                    HStack(spacing: 12) {
                        SettingsListIcon(symbol: "arrow.clockwise", color: .purple)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(camera.recoverableRecordingCount) Recording\(camera.recoverableRecordingCount == 1 ? "" : "s") Waiting")
                            Text("Retry videos that Photos could not import earlier.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Retry") {
                            camera.retryRecoverableRecordings()
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.vertical, 2)
                }
            }

            Section("SAFETY") {
                SettingsInfoRow(
                    symbol: "externaldrive.fill.badge.checkmark",
                    color: .blue,
                    title: "Low-Storage Protection",
                    detail: "Critical storage monitoring is always active while recording and safely finalizes the clip before space is exhausted."
                )

                SettingsInfoRow(
                    symbol: "square.and.arrow.down.fill",
                    color: .green,
                    title: "Background Save Protection",
                    detail: "Pending photo and video saves are protected when LowPolyCam moves to the background."
                )
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Advanced Recording")
        .navigationBarTitleDisplayMode(.large)
        .tint(.blue)
        .preferredColorScheme(resolvedColorScheme(appColorScheme))
    }
}
