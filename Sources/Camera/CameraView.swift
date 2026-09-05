import SwiftUI

struct CameraView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var camera = CameraManager()
    @StateObject private var levelMonitor = CameraLevelMonitor()
    @AppStorage("levelMeterEnabled") private var isLevelMeterEnabled = true
    @State private var isShowingSettings = false
    @State private var isShowingProTools = false
    @State private var dragStartZoom: CGFloat?

    var body: some View {
        ZStack {
            CameraPreview(
                session: camera.session,
                isFocusExposureLocked: camera.isFocusExposureLocked,
                exposureBias: camera.exposureBias,
                onTapToFocus: { camera.focusAndExpose(at: $0) },
                onLongPressToLock: { camera.lockFocusAndExposure(at: $0) },
                onExposureDragBegan: { camera.beginExposureAdjustment() },
                onExposureDragChanged: { camera.adjustExposure(by: $0) }
            )
            .ignoresSafeArea()

            LinearGradient(colors: [.black.opacity(0.48), .clear, .black.opacity(0.60)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            if isLevelMeterEnabled {
                CameraLevelOverlay(
                    angle: levelMonitor.angle,
                    isAvailable: levelMonitor.isAvailable,
                    isLevel: levelMonitor.isLevel
                )
                .offset(y: -8)
                .allowsHitTesting(false)
            }

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

            if isShowingProTools {
                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .onTapGesture { isShowingProTools = false }

                VStack {
                    Spacer()
                    HStack {
                        ProToolsPopup(camera: camera, isLevelMeterEnabled: $isLevelMeterEnabled)
                        Spacer()
                    }
                }
                .padding(.leading, 14)
                .padding(.bottom, 132)
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottomLeading)))
            }

            if let message = camera.statusMessage {
                VStack {
                    Spacer()
                    Text(message)
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 11)
                        .background(.black.opacity(0.75), in: Capsule())
                        .foregroundStyle(.white)
                        .padding(.bottom, 176)
                }
                .transition(.opacity)
                .task(id: message) {
                    try? await Task.sleep(for: .seconds(3))
                    if camera.statusMessage == message { camera.statusMessage = nil }
                }
            }
        }
        .preferredColorScheme(.dark)
        .task {
            camera.start()
            if isLevelMeterEnabled { levelMonitor.start() }
        }
        .onChange(of: isLevelMeterEnabled) { _, enabled in
            if enabled, scenePhase == .active {
                levelMonitor.start()
            } else {
                levelMonitor.stop()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                camera.appDidBecomeActive()
                if isLevelMeterEnabled { levelMonitor.start() }
            } else {
                camera.appDidBecomeInactive()
                levelMonitor.stop()
            }
        }
        .onDisappear {
            levelMonitor.stop()
            camera.stop()
        }
        .sheet(isPresented: $isShowingSettings) {
            VideoSettingsView(camera: camera)
                .presentationDetents([.medium])
        }
    }

    private var topControls: some View {
        HStack {
            CameraIconButton(symbol: "bolt.fill", isEnabled: camera.torchAvailable, color: camera.isTorchOn ? .yellow : .white) {
                camera.toggleTorch()
            }
            Spacer()
            CameraIconButton(symbol: "gearshape.fill", isEnabled: !camera.isRecording && !camera.isCapturingPhoto, color: .white) {
                isShowingSettings = true
            }
        }
    }

    private var bottomControls: some View {
        HStack {
            CameraIconButton(symbol: "ellipsis", isEnabled: !camera.isRecording && !camera.isCapturingPhoto, color: .white) {
                withAnimation(.easeOut(duration: 0.16)) {
                    isShowingProTools.toggle()
                }
            }
            Spacer()
            VStack(spacing: 16) {
                ZStack {
                    Color.clear
                    ZoomIndicator(label: camera.zoomLabel)
                }
                .contentShape(Rectangle())
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .gesture(zoomGesture)

                CaptureModeSelector(
                    selectedMode: camera.captureMode,
                    isEnabled: !camera.isRecording && !camera.isCapturingPhoto,
                    onSelect: { camera.selectCaptureMode($0) }
                )

                if camera.captureMode == .photo {
                    PhotoButton(isCapturing: camera.isCapturingPhoto) {
                        camera.capturePhoto()
                    }
                } else {
                    if camera.captureMode == .sloMo {
                        Text(camera.selectedSlowMotionFrameRate.label.uppercased())
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.75))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(.black.opacity(0.32), in: Capsule())
                    }

                    RecordButton(isRecording: camera.isRecording) {
                        camera.startOrStopRecording()
                    }
                }
            }
            Spacer()
            CameraIconButton(symbol: "camera.rotate", isEnabled: !camera.isRecording && !camera.isCapturingPhoto, color: .white) {
                camera.switchCamera()
            }
        }
        .padding(.bottom, 8)
    }

    private var zoomGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if dragStartZoom == nil {
                    dragStartZoom = camera.zoomFactor
                }
                guard let dragStartZoom else { return }
                let screenWidth = max(UIScreen.main.bounds.width, 1)
                let zoomRange = camera.maximumZoomFactor - camera.minimumZoomFactor
                let requestedZoom = dragStartZoom - (value.translation.width / screenWidth * zoomRange)
                camera.setZoomFactor(requestedZoom)
            }
            .onEnded { _ in
                dragStartZoom = nil
            }
    }
}
