import SwiftUI

struct VideoSettingsView: View {
    @ObservedObject var camera: CameraManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Video Quality") {
                    Picker("Resolution", selection: Binding(
                        get: { camera.selectedResolution },
                        set: { camera.selectResolution($0) }
                    )) {
                        ForEach(camera.supportedResolutions) { resolution in
                            Text(resolution.rawValue).tag(resolution)
                        }
                    }

                    Picker("Frame Rate", selection: Binding(
                        get: { camera.selectedFrameRate },
                        set: { camera.selectFrameRate($0) }
                    )) {
                        ForEach(camera.supportedFrameRates) { frameRate in
                            Text(frameRate.label).tag(frameRate)
                        }
                    }
                }

                Section {
                    Text("Only options supported by the active camera are shown.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
