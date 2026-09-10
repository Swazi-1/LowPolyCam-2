import AVFoundation
import Foundation
import SwiftUI

struct AdvancedRecordingSettingsView: View {
    @ObservedObject var camera: CameraManager
    var positionStats: () -> Void

    @AppStorage("splitMinutes") private var splitMinutes = 0
    @AppStorage("longevityMode") private var longevity = false
    @AppStorage("liveRecordingStats") private var liveStats = false
    @State private var showingRecoveryDeleteConfirmation = false
    @State private var recoveryFileToDelete: URL?

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
                    .pickerStyle(.menu)
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

            if camera.recoverableRecordingCount > 0 || camera.recoverablePhotoCount > 0 {
                Section("RECOVERY") {
                    if camera.recoverableRecordingCount > 0 {
                        Text("RECORDINGS")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(camera.recoverableRecordingFiles, id: \.self) { file in
                            RecoveryFileRow(file: file, mediaKind: "Recording", onDelete: { recoveryFileToDelete = file })
                        }
                        Button {
                            camera.retryRecoverableRecordings()
                        } label: {
                            Label("Retry All Recordings", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.bordered)
                    }

                    if camera.recoverablePhotoCount > 0 {
                        Text("PHOTOS")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(camera.recoverablePhotoFiles, id: \.self) { file in
                            RecoveryFileRow(file: file, mediaKind: "Photo", onDelete: { recoveryFileToDelete = file })
                        }
                        Button {
                            camera.retryRecoverablePhotos()
                        } label: {
                            Label("Retry All Photos", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.bordered)
                    }

                    Button("Delete All Recovery Files", role: .destructive) {
                        showingRecoveryDeleteConfirmation = true
                    }
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

                if camera.captureMode != .photo {
                    SettingsInfoRow(
                        symbol: "mic.fill",
                        color: camera.audioStatusLabel == "Audio" ? .green : .orange,
                        title: "Audio: \(camera.audioStatusLabel)",
                        detail: camera.audioStatusLabel == "Audio"
                            ? "The microphone is attached to video recording."
                            : "Recording can continue silently. To enable audio, allow LowPolyCam under Settings > Privacy & Security > Microphone."
                    )
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Advanced Recording")
        .navigationBarTitleDisplayMode(.large)
        .tint(.blue)
        .confirmationDialog(
            "Delete all Recovery files?",
            isPresented: $showingRecoveryDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete All", role: .destructive) {
                camera.deleteAllRecoveryFiles()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes recordings and photos that have not been imported into Photos.")
        }
        .confirmationDialog(
            "Delete recovered file?",
            isPresented: Binding(
                get: { recoveryFileToDelete != nil },
                set: { if !$0 { recoveryFileToDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let file = recoveryFileToDelete {
                    camera.deleteRecoveryFile(file)
                }
                recoveryFileToDelete = nil
            }
            Button("Cancel", role: .cancel) {
                recoveryFileToDelete = nil
            }
        } message: {
            Text("This permanently removes the selected file from Recovery.")
        }
    }
}

private struct RecoveryFileRow: View {
    let file: URL
    let mediaKind: String
    let onDelete: () -> Void
    @State private var fileSize: Int64 = 0
    @State private var modifiedDate: Date?
    @State private var duration: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                SettingsListIcon(symbol: mediaKind == "Photo" ? "photo" : "film", color: mediaKind == "Photo" ? .orange : .purple)
                Text(file.lastPathComponent)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Spacer()
                ShareLink(item: file) {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("Share recovered \(mediaKind.lowercased())")
            }
            HStack(spacing: 8) {
                Text(mediaKind)
                if fileSize > 0 { Text(formatBytes(fileSize)) }
                if let duration, duration.isFinite, duration > 0 {
                    Text(formatDuration(duration))
                }
                if let modifiedDate {
                    Text(modifiedDate.formatted(date: .abbreviated, time: .shortened))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.leading, 36)
        }
        .task(id: file) {
            let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            fileSize = Int64(values?.fileSize ?? 0)
            modifiedDate = values?.contentModificationDate
            if mediaKind == "Recording" {
                let asset = AVURLAsset(url: file)
                let seconds = asset.duration.seconds
                duration = seconds.isFinite ? seconds : nil
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive, action: onDelete) {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
