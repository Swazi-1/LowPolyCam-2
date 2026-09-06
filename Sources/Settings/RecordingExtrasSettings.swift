import SwiftUI

struct LiveStatsOverlay: View {
    @ObservedObject var camera: CameraManager
    var editing: Bool
    var finish: () -> Void
    @AppStorage("liveStatsX") private var x = 0.5
    @AppStorage("liveStatsY") private var y = 0.28
    @State private var dragOrigin: CGPoint?
    @Environment(\.cameraTint) private var theme

    var body: some View {
        GeometryReader { proxy in
            let width = min(CGFloat(238), max(120, proxy.size.width - 24))
            let height: CGFloat = 110
            let travelX = max(1, proxy.size.width - width - 24)
            let travelY = max(1, proxy.size.height - height - 24)
            VStack(alignment: .leading, spacing: 6) {
                Text(editing ? "DRAG TO POSITION" : "LIVE RECORDING").font(.caption2.bold()).foregroundStyle(theme)
                metric("Capture FPS", camera.liveFPS.map { String(format: "%.1f", $0) } ?? "—")
                metric("File bitrate", camera.liveMbps.map { String(format: "%.1f Mbps", $0) } ?? "—")
                metric("Capture drops", camera.liveCaptureDrops.map { String($0) } ?? "—")
            }
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .foregroundStyle(.white)
            .padding(12)
            .frame(width: width, height: height)
            .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(theme.opacity(0.65)))
            .position(x: 12 + width / 2 + CGFloat(min(max(x, 0), 1)) * travelX,
                      y: 12 + height / 2 + CGFloat(min(max(y, 0), 1)) * travelY)
            .gesture(DragGesture().onChanged { value in
                guard editing else { return }
                if dragOrigin == nil { dragOrigin = CGPoint(x: x, y: y) }
                guard let origin = dragOrigin else { return }
                x = min(max(Double(origin.x + value.translation.width / travelX), 0), 1)
                y = min(max(Double(origin.y + value.translation.height / travelY), 0), 1)
            }.onEnded { _ in dragOrigin = nil })
            .allowsHitTesting(editing)

            if editing {
                VStack {
                    HStack {
                        Button("Reset") { x = 0.5; y = 0.28 }
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
        HStack { Text(title); Spacer(minLength: 8); Text(value).monospacedDigit() }
    }
}

struct RecordingExtrasSettings: View {
    @ObservedObject var camera: CameraManager
    var positionStats: () -> Void
    @AppStorage("longevityMode") private var longevity = false
    @AppStorage("liveRecordingStats") private var stats = false
    var body: some View {
        SettingsCard(title: "Long Sessions & Stats", symbol: "battery.100percent") {
            SettingsToggleRow(title: "Longevity Mode", subtitle: "Uses 720p · 30 fps · HEVC · Data Saver for video and dims the screen while recording. Previous video settings return when disabled.", isOn: Binding(get: { longevity }, set: { camera.applyLongevityMode($0) }))
            SettingsDivider()
            SettingsToggleRow(title: "Live Recording Stats", subtitle: "Measured capture FPS, file bitrate and capture-output drops. Encoder drops are not exposed by iOS. Adds some processing overhead.", isOn: $stats)
            if stats {
                Button("Position Live Stats", action: positionStats).padding(.vertical, 8)
                Text("Drag the panel on your camera screen. Camera buttons are disabled in the editor. Measurements appear during recording; — means unavailable.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .onChange(of: stats) { _, _ in camera.refreshLiveMetrics() }
    }
}
