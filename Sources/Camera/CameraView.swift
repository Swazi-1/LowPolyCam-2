import SwiftUI

struct CameraView: View {
    @StateObject private var camera = CameraManager()
    @State private var isShowingSettings = false

    var body: some View {
        ZStack {
            CameraPreview(session: camera.session)
                .ignoresSafeArea()

            LinearGradient(colors: [.black.opacity(0.48), .clear, .black.opacity(0.60)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            VStack {
                topControls
                Spacer()
                if camera.isRecording {
                    RecordingTimer(duration: camera.recordingDuration)
                        .padding(.bottom, 18)
                }
                bottomControls
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)

            if let message = camera.statusMessage {
                VStack {
                    Spacer()
                    Text(message)
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 11)
                        .background(.black.opacity(0.75), in: Capsule())
                        .foregroundStyle(.white)
                        .padding(.bottom, 132)
                }
                .transition(.opacity)
                .task(id: message) {
                    try? await Task.sleep(for: .seconds(3))
                    if camera.statusMessage == message { camera.statusMessage = nil }
                }
            }
        }
        .preferredColorScheme(.dark)
        .task { camera.start() }
        .onDisappear { camera.stop() }
        .sheet(isPresented: $isShowingSettings) {
            VideoSettingsView(camera: camera)
                .presentationDetents([.medium])
        }
    }

    private var topControls: some View {
        HStack {
            CameraIconButton(symbol: "bolt.fill", isEnabled: camera.torchAvailable) {
                camera.toggleTorch()
            }
            Spacer()
            CameraIconButton(symbol: "gearshape.fill", isEnabled: !camera.isRecording) {
                isShowingSettings = true
            }
        }
    }

    private var bottomControls: some View {
        HStack {
            Color.clear.frame(width: 48, height: 48)
            Spacer()
            RecordButton(isRecording: camera.isRecording) {
                camera.startOrStopRecording()
            }
            Spacer()
            CameraIconButton(symbol: "camera.rotate", isEnabled: !camera.isRecording) {
                camera.switchCamera()
            }
        }
        .padding(.bottom, 8)
    }
}
