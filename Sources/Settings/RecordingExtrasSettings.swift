import SwiftUI

struct LiveStatsOverlay: View {
    @ObservedObject var stats: LiveRecordingStatsState
    var editing: Bool
    var finish: () -> Void
    @AppStorage("liveStatsX") private var x = 0.5
    @AppStorage("liveStatsY") private var y = 0.28
    @AppStorage("liveStatsSize") private var size = "Normal"
    @AppStorage("liveStatsShowFPS") private var showFPS = true
    @AppStorage("liveStatsShowBitrate") private var showBitrate = true
    @AppStorage("liveStatsShowDrops") private var showDrops = true
    @State private var dragOrigin: CGPoint?
    @State private var dragPosition: CGPoint?
    @Environment(\.cameraTint) private var theme

    var body: some View {
        GeometryReader { proxy in
            let compact = size == "Compact"
            let width = min(CGFloat(compact ? 176 : 238), max(120, proxy.size.width - 24))
            let rows = max(1, [showFPS, showBitrate, showDrops].filter { $0 }.count)
            let height = CGFloat(rows * (compact ? 17 : 22) + (compact ? 16 : 24) + ((!compact || editing) ? 20 : 0))
            let travelX = max(1, proxy.size.width - width - 24)
            let travelY = max(1, proxy.size.height - height - 24)
            VStack(alignment: .leading, spacing: 6) {
                if !compact || editing {
                    Text(editing ? "DRAG TO POSITION" : "LIVE RECORDING").font(.caption2.bold()).foregroundStyle(theme)
                }
                if showFPS { metric(compact ? "FPS" : "Capture FPS", stats.fps.map { String(format: "%.1f", $0) } ?? "—") }
                if showBitrate { metric(compact ? "Bitrate" : "File bitrate", stats.mbps.map { String(format: "%.1f Mbps", $0) } ?? "—") }
                if showDrops { metric(compact ? "Drops*" : "Capture drops", stats.drops.map { String($0) } ?? "N/A") }
                if !showFPS && !showBitrate && !showDrops { Text("No stats selected").font(.caption) }
            }
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .foregroundStyle(.white)
            .padding(compact ? 8 : 12)
            .frame(width: width, height: height)
            .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(theme.opacity(0.65)))
            .position(x: 12 + width / 2 + CGFloat(min(max(dragPosition.map { Double($0.x) } ?? x, 0), 1)) * travelX,
                      y: 12 + height / 2 + CGFloat(min(max(dragPosition.map { Double($0.y) } ?? y, 0), 1)) * travelY)
            .gesture(DragGesture().onChanged { value in
                guard editing else { return }
                if dragOrigin == nil {
                    let origin = CGPoint(x: CGFloat(x), y: CGFloat(y))
                    dragOrigin = origin
                    dragPosition = origin
                }
                guard let origin = dragOrigin else { return }
                dragPosition = CGPoint(
                    x: min(max(origin.x + value.translation.width / travelX, 0), 1),
                    y: min(max(origin.y + value.translation.height / travelY, 0), 1)
                )
            }.onEnded { _ in
                if let final = dragPosition {
                    x = Double(final.x)
                    y = Double(final.y)
                }
                dragOrigin = nil
                dragPosition = nil
            })
            .allowsHitTesting(editing)

            if editing {
                VStack {
                    HStack {
                        Button("Reset") { dragOrigin = nil; dragPosition = nil; x = 0.5; y = 0.28 }
                        Spacer()
                        Button("Done", action: finish).fontWeight(.bold)
                    }
                    .padding().background(.black.opacity(0.85), in: Capsule())
                    Spacer()
                }.padding(12).tint(theme)
            }
        }
        .dynamicTypeSize(.medium ... .large)
    }

    private func metric(_ title: String, _ value: String) -> some View {
        HStack { Text(title); Spacer(minLength: 6); Text(value).monospacedDigit() }
            .lineLimit(1).minimumScaleFactor(0.75)
    }
}

struct RecordingExtrasSettings: View {
    @ObservedObject var camera: CameraManager
    var positionStats: () -> Void
    @AppStorage("longevityMode") private var longevity = false
    @AppStorage("liveRecordingStats") private var stats = false

    var body: some View {
        Group {
            if camera.captureMode == .video {
                Toggle("Longevity Mode", isOn: Binding(
                    get: { longevity },
                    set: { camera.applyLongevityMode($0) }
                ))
                Toggle("Live Recording Stats", isOn: $stats)
            } else if camera.captureMode == .sloMo {
                Toggle("Live Recording Stats", isOn: $stats)
            }
        }
        .onChange(of: stats) { _, _ in camera.refreshLiveMetrics() }
    }
}

struct LiveStatsSettings: View {
    var positionStats: () -> Void
    @AppStorage("liveStatsSize") private var size = "Normal"
    @AppStorage("liveStatsShowFPS") private var showFPS = true
    @AppStorage("liveStatsShowBitrate") private var showBitrate = true
    @AppStorage("liveStatsShowDrops") private var showDrops = true

    var body: some View {
        List {
            Section {
                Picker("Panel Size", selection: $size) {
                    Text("Compact").tag("Compact")
                    Text("Normal").tag("Normal")
                }
                .pickerStyle(.menu)
            } header: {
                Text("APPEARANCE")
            } footer: {
                Text("Compact uses shorter labels and less screen space.")
            }

            Section {
                Toggle("Capture FPS", isOn: $showFPS)
                Toggle("File Bitrate", isOn: $showBitrate)
                Toggle("Capture Drops", isOn: $showDrops)
            } header: {
                Text("INFORMATION")
            } footer: {
                Text("Capture Drops are gaps observed by the monitoring output; they are not a direct encoder-drop count.")
            }

            Section {
                Button {
                    positionStats()
                } label: {
                    Label("Position Live Stats", systemImage: "arrow.up.and.down.and.arrow.left.and.right")
                }
            } header: {
                Text("POSITION")
            } footer: {
                Text("The Settings sheet closes so you can drag the stats panel directly on the camera screen.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Live Stats")
        .navigationBarTitleDisplayMode(.large)
        .tint(.blue)
    }
}
