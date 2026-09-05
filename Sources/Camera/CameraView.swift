import SwiftUI
import UIKit

struct CameraView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var camera = CameraManager()
    @StateObject private var levelMonitor = CameraLevelMonitor()
    @AppStorage("levelMeterEnabled") private var isLevelMeterEnabled = true
    @AppStorage("cameraGridEnabled") private var isGridEnabled = false
    @AppStorage("cameraHUDEnabled") private var isHUDEnabled = true
    @AppStorage("cameraHUDResolution") private var hudResolution = true
    @AppStorage("cameraHUDFPS") private var hudFPS = true
    @AppStorage("cameraHUDRemaining") private var hudRemaining = true
    @AppStorage("cameraHUDZoom") private var hudZoom = false
    @AppStorage("cameraHUDWhiteBalance") private var hudWhiteBalance = false
    @AppStorage("hapticCaptureEnabled") private var isHapticCaptureEnabled = true
    @AppStorage("keepScreenAwakeEnabled") private var keepScreenAwakeEnabled = false
    @State private var isShowingSettings = false
    @State private var isShowingProTools = false
    @State private var dragStartZoom: CGFloat?

    var body: some View {
        ZStack {
            CameraPreview(
                session: camera.session,
                isFocusExposureLocked: camera.isFocusExposureLocked,
                stabilizationEnabled: camera.captureMode == .video && camera.isVideoStabilizationEnabled,
                isPreviewTransitioning: camera.isPreviewTransitioning,
                onTapToFocus: { camera.focusAndExpose(at: $0) },
                onLongPressToLock: { camera.lockFocusAndExposure(at: $0) }
            )
            .ignoresSafeArea()

            LinearGradient(colors: [.black.opacity(0.48), .clear, .black.opacity(0.60)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            if isGridEnabled {
                CameraGridOverlay()
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }

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
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    if camera.statusMessage == message { camera.statusMessage = nil }
                }
            }
        }
        .preferredColorScheme(.dark)
        .task {
            camera.start()
            camera.refreshAvailableStorage()
            updateIdleTimer(for: scenePhase)
            if isLevelMeterEnabled { levelMonitor.start() }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if Task.isCancelled { break }
                camera.refreshAvailableStorage()
            }
        }
        .onChange(of: isLevelMeterEnabled) { _, enabled in
            if enabled, scenePhase == .active {
                levelMonitor.start()
            } else {
                levelMonitor.stop()
            }
        }
        .onChange(of: keepScreenAwakeEnabled) { _, _ in
            updateIdleTimer(for: scenePhase)
        }
        .onChange(of: scenePhase) { _, phase in
            updateIdleTimer(for: phase)
            if phase == .active {
                camera.appDidBecomeActive()
                camera.refreshAvailableStorage()
                if isLevelMeterEnabled { levelMonitor.start() }
            } else {
                camera.appDidBecomeInactive()
                levelMonitor.stop()
            }
        }
        .onDisappear {
            levelMonitor.stop()
            camera.stop()
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .sheet(isPresented: $isShowingSettings) {
            VideoSettingsView(camera: camera)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    private var topControls: some View {
        GeometryReader { proxy in
            let hudMaxWidth = max(120, proxy.size.width - 112)

            ZStack {
                HStack {
                    CameraIconButton(symbol: "bolt.fill", isEnabled: camera.torchAvailable, color: camera.isTorchOn ? .yellow : .white) {
                        camera.toggleTorch()
                    }
                    Spacer()
                    CameraIconButton(symbol: "gearshape.fill", isEnabled: !camera.isRecording && !camera.isCapturingPhoto, color: .white) {
                        isShowingSettings = true
                    }
                }

                if isHUDEnabled {
                    CameraHUD(
                        camera: camera,
                        showResolution: hudResolution,
                        showFPS: hudFPS,
                        showRemaining: hudRemaining,
                        showZoom: hudZoom,
                        showWhiteBalance: hudWhiteBalance,
                        maxWidth: hudMaxWidth
                    )
                    .allowsHitTesting(false)
                }
            }
        }
        .frame(height: 48)
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
                        captureHaptic()
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
                        captureHaptic()
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

    private func captureHaptic() {
        guard isHapticCaptureEnabled else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    private func updateIdleTimer(for phase: ScenePhase) {
        UIApplication.shared.isIdleTimerDisabled = keepScreenAwakeEnabled && phase == .active
    }
}
