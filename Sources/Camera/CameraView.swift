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
    @AppStorage("cameraHUDWhiteBalance") private var hudWhiteBalance = false
    @AppStorage("hapticCaptureEnabled") private var isHapticCaptureEnabled = true
    @AppStorage("keepScreenAwakeEnabled") private var keepScreenAwakeEnabled = false
    @State private var isShowingSettings = false
    @State private var isShowingProTools = false
    @State private var dragStartZoom: CGFloat?
    @State private var countdown = 0
    @State private var shutterTask: Task<Void, Never>?
    @State private var zoomWidth: CGFloat = 320
    @AppStorage("shutterDelay") private var shutterDelay = 0
    @AppStorage("centerCrosshair") private var crosshair = false
    @AppStorage("zoomSpeed") private var zoomSpeed = 1.0
    @AppStorage("tapZoomReset") private var tapZoomReset = true
    @AppStorage("recordingLock") private var recordingLock = false
    @AppStorage("lowStorageWarning") private var lowStorageWarning = true
    @AppStorage("gridOpacity") private var gridOpacity = 1.0
    @AppStorage("countdownHaptics") private var countdownHaptics = false
    @AppStorage("mirrorSelfies") private var mirrorSelfies = false
    @State private var warnedAboutStorage = false
    @AppStorage("liveRecordingStats") private var liveStats = false
    @AppStorage("photoAspect") private var photoAspect = "4:3"
    @AppStorage("longevityMode") private var longevity = false
    @State private var editingStats = false
    @State private var restoreBrightness: CGFloat?
    private var accent = CameraAccent()

    var body: some View {
        ZStack {
            CameraPreview(
                session: camera.session,
                isFocusExposureLocked: camera.isFocusExposureLocked,
                stabilizationEnabled: camera.captureMode == .video && camera.isVideoStabilizationEnabled,
                isPreviewTransitioning: camera.isPreviewTransitioning,
                fitsPhoto: camera.captureMode == .photo,
                onTapToFocus: { if !editingStats { camera.focusAndExpose(at: $0) } },
                onLongPressToLock: { if !editingStats { camera.lockFocusAndExposure(at: $0) } }
            )
            .ignoresSafeArea()
            .allowsHitTesting(!editingStats && !camera.isPreviewTransitioning && !camera.isCapturingPhoto && !(camera.isRecording && recordingLock))

            if camera.captureMode == .photo && photoAspect == "1:1" {
                GeometryReader { proxy in
                    let side = min(proxy.size.width, proxy.size.height)
                    VStack(spacing: 0) {
                        Color.black.opacity(0.7)
                        Color.clear.frame(height: side).overlay(Rectangle().stroke(.white.opacity(0.5)))
                        Color.black.opacity(0.7)
                    }
                }.ignoresSafeArea().allowsHitTesting(false)
            }

            LinearGradient(colors: [.black.opacity(0.48), .clear, .black.opacity(0.60)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            if isGridEnabled {
                CameraGridOverlay()
                    .opacity(gridOpacity)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }

            if crosshair {
                Image(systemName: "plus")
                    .font(.system(size: 22, weight: .ultraLight))
                    .foregroundStyle(.white.opacity(0.7))
                    .allowsHitTesting(false)
            }

            if countdown > 0 {
                Button { cancelCountdown() } label: {
                    VStack {
                        Text("\(countdown)").font(.system(size: 64, weight: .bold, design: .rounded))
                        Text("Tap to cancel").font(.caption)
                    }
                    .padding(24)
                    .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 24))
                }.foregroundStyle(.white).zIndex(10)
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
                bottomControls
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
            .allowsHitTesting(!editingStats && !camera.isPreviewTransitioning)

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
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 11)
                        .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 18))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 176)
                }
                .transition(.opacity)
                .allowsHitTesting(false)
                .task(id: camera.statusMessageID) {
                    let id = camera.statusMessageID
                    do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { return }
                    camera.clearStatus(id: id)
                }
            }
        }
        .overlay {
            if editingStats || (liveStats && camera.isRecording) {
                LiveStatsOverlay(camera: camera, editing: editingStats) { editingStats = false }
            }
        }
        .onChange(of: camera.isRecording) { _, recording in
            if recording && longevity && camera.captureMode == .video {
                if restoreBrightness == nil { restoreBrightness = UIScreen.main.brightness }
                UIScreen.main.brightness = min(UIScreen.main.brightness, 0.25)
            } else if let brightness = restoreBrightness {
                UIScreen.main.brightness = brightness
                restoreBrightness = nil
            }
        }
        .preferredColorScheme(.dark)
        .tint(accent.color)
        .task {
            camera.start()
            camera.refreshAvailableStorage()
            updateIdleTimer(for: scenePhase)
            if isLevelMeterEnabled { levelMonitor.start() }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
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
        .onChange(of: mirrorSelfies) { _, _ in
            camera.refreshMovieOutputSettings()
        }
        .onChange(of: scenePhase) { _, phase in
            updateIdleTimer(for: phase)
            if phase == .active {
                camera.appDidBecomeActive()
                camera.refreshAvailableStorage()
                if isLevelMeterEnabled { levelMonitor.start() }
            } else {
                cancelCountdown()
                if let brightness = restoreBrightness {
                    UIScreen.main.brightness = brightness
                    restoreBrightness = nil
                }
                camera.appDidBecomeInactive()
                levelMonitor.stop()
            }
        }
        .onDisappear {
            cancelCountdown()
            levelMonitor.stop()
            camera.stop()
            if let brightness = restoreBrightness { UIScreen.main.brightness = brightness; restoreBrightness = nil }
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .sheet(isPresented: $isShowingSettings) {
            VideoSettingsView(camera: camera) {
                isShowingSettings = false
                isShowingProTools = false
                cancelCountdown()
                editingStats = true
            }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .onChange(of: camera.captureMode) { _, _ in cancelCountdown() }
        .onChange(of: camera.availableStorageBytes) { _, bytes in
            if bytes > 1_000_000_000 { warnedAboutStorage = false }
            if lowStorageWarning, bytes > 0, bytes < 1_000_000_000, !warnedAboutStorage {
                warnedAboutStorage = true
                camera.postStatus("Storage is below 1 GB. Long recordings may stop early.")
            }
        }
        .onChange(of: isShowingSettings) { _, showing in if showing { cancelCountdown() } }
    }

    private var topControls: some View {
        GeometryReader { proxy in
            let hudMaxWidth = max(120, proxy.size.width - 112)

            ZStack {
                HStack {
                    CameraIconButton(symbol: "bolt.fill", isEnabled: camera.torchAvailable && !(camera.isRecording && recordingLock), color: camera.isTorchOn ? accent.color : accent.color.opacity(0.65)) {
                        camera.toggleTorch()
                    }
                    Spacer()
                    CameraIconButton(symbol: "gearshape.fill", isEnabled: !camera.isRecording && !camera.isRecordingStarting && !camera.isFinalizingRecording && !camera.isCapturingPhoto, color: accent.color) {
                        isShowingSettings = true
                    }
                }

                if isHUDEnabled {
                    CameraHUD(
                        camera: camera,
                        showResolution: hudResolution,
                        showFPS: hudFPS,
                        showRemaining: hudRemaining,
                        showWhiteBalance: hudWhiteBalance,
                        maxWidth: hudMaxWidth
                    )
                    .allowsHitTesting(false)
                } else if camera.isRecording {
                    RecordingTimer(duration: camera.recordingDuration)
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(height: 116)
    }

    private var bottomControls: some View {
        VStack(spacing: 14) {
                ZStack {
                    Color.clear
                    ZoomIndicator(label: camera.zoomLabel)
                }
                .contentShape(Rectangle())
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .padding(.horizontal, -22)
                .background(GeometryReader { proxy in
                    Color.clear.onAppear { zoomWidth = proxy.size.width }
                        .onChange(of: proxy.size.width) { _, width in zoomWidth = width }
                })
                .gesture(zoomGesture)
                .allowsHitTesting(!(camera.isRecording && recordingLock))

                CaptureModeSelector(
                    selectedMode: camera.captureMode,
                    isEnabled: !camera.isRecording && !camera.isRecordingStarting && !camera.isFinalizingRecording && !camera.isCapturingPhoto && countdown == 0,
                    onSelect: { camera.selectCaptureMode($0) }
                )
                .padding(.bottom, 8)

            HStack {
                CameraIconButton(symbol: "ellipsis", isEnabled: !camera.isRecording && !camera.isRecordingStarting && !camera.isFinalizingRecording && !camera.isCapturingPhoto && countdown == 0, color: accent.color) {
                    withAnimation(.easeOut(duration: 0.16)) { isShowingProTools.toggle() }
                }
                Spacer()
                if camera.captureMode == .photo {
                    PhotoButton(isCapturing: camera.isCapturingPhoto) { shutterPressed() }
                        .highPriorityGesture(
                            LongPressGesture(minimumDuration: 0.45).exclusively(before: TapGesture())
                                .onEnded { value in
                                    guard !editingStats else { return }
                                    switch value {
                                    case .first:
                                        cancelCountdown()
                                        captureHaptic()
                                        camera.captureBurst()
                                    case .second: shutterPressed()
                                    }
                                }
                        )
                } else if camera.isRecording && recordingLock {
                    Image(systemName: "lock.fill")
                        .font(.title2).foregroundStyle(accent.color)
                        .frame(width: 76, height: 76)
                        .background(.black.opacity(0.6), in: Circle())
                        .overlay(Circle().stroke(.red, lineWidth: 3))
                        .onLongPressGesture(minimumDuration: 1) { CameraHaptics.fire(captureOnly: true); camera.startOrStopRecording() }
                        .accessibilityLabel("Recording locked. Hold to stop")
                        .accessibilityAction(named: "Stop recording") { camera.startOrStopRecording() }
                } else {
                    RecordButton(isRecording: camera.isRecording, isEnabled: !camera.isRecordingStarting && !camera.isFinalizingRecording) {
                        shutterPressed()
                    }
                }
            Spacer()
            CameraIconButton(symbol: "camera.rotate", isEnabled: !camera.isRecording && !camera.isRecordingStarting && !camera.isFinalizingRecording && !camera.isCapturingPhoto && countdown == 0, color: accent.color) {
                camera.switchCamera()
            }
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
                let screenWidth = max(zoomWidth, 1)
                let zoomRange = camera.maximumZoomFactor - camera.minimumZoomFactor
                let requestedZoom = dragStartZoom - (value.translation.width / screenWidth * zoomRange * zoomSpeed)
                camera.setZoomFactor(requestedZoom)
            }
            .onEnded { value in
                if tapZoomReset, abs(value.translation.width) < 4, abs(value.translation.height) < 4 {
                    camera.setZoomFactor(1)
                }
                dragStartZoom = nil
            }
    }

    private func captureHaptic() {
        guard isHapticCaptureEnabled else { return }
        CameraHaptics.fire(captureOnly: true)
    }

    private func cancelCountdown() {
        shutterTask?.cancel()
        shutterTask = nil
        countdown = 0
    }

    private func shutterPressed() {
        if countdown > 0 { cancelCountdown(); return }
        if camera.isRecording { captureHaptic(); camera.startOrStopRecording(); return }
        guard !camera.isRecordingStarting, !camera.isFinalizingRecording,
              shutterTask == nil, camera.isSessionRunning else { return }
        let mode = camera.captureMode
        shutterTask = Task { @MainActor in
            countdown = shutterDelay
            while countdown > 0 {
                if countdownHaptics { CameraHaptics.fire() }
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
                guard !Task.isCancelled else { return }
                countdown -= 1
            }
            guard !Task.isCancelled, scenePhase == .active, camera.captureMode == mode else { return }
            captureHaptic()
            if mode == .photo { camera.capturePhoto() } else { camera.startOrStopRecording() }
            shutterTask = nil
        }
    }

    private func updateIdleTimer(for phase: ScenePhase) {
        UIApplication.shared.isIdleTimerDisabled = keepScreenAwakeEnabled && phase == .active
    }
}
