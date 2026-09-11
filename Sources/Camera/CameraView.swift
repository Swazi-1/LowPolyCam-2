import SwiftUI
import UIKit

private struct CameraTopControlsHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct CameraLowerControlsHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct CameraView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var camera = CameraManager()
    @AppStorage("levelMeterEnabled") private var isLevelMeterEnabled = false
    @AppStorage("cameraGridEnabled") private var isGridEnabled = false
    @AppStorage("gridStyle") private var gridStyle = GridStyle.ruleOfThirds.rawValue
    @AppStorage("cameraHUDEnabled") private var isHUDEnabled = true
    @AppStorage("cameraHUDResolution") private var hudResolution = true
    @AppStorage("cameraHUDFPS") private var hudFPS = true
    @AppStorage("cameraHUDRemaining") private var hudRemaining = false
    @AppStorage("cameraHUDWhiteBalance") private var hudWhiteBalance = false
    @AppStorage("frameGuidesEnabled") private var frameGuidesEnabled = false
    @AppStorage("photoCaptureFlash") private var photoCaptureFlash = true
    @AppStorage("frontScreenFlash") private var frontScreenFlash = false
    @AppStorage("appColorScheme") private var appColorScheme = "dark"
    @AppStorage("hapticCaptureEnabled") private var isHapticsEnabled = true
    @AppStorage("keepScreenAwakeEnabled") private var keepScreenAwakeEnabled = false
    @State private var isShowingSettings = false
    @State private var isShowingProTools = false
    @State private var dragStartZoom: CGFloat?
    @State private var countdown = 0
    @State private var shutterTask: Task<Void, Never>?
    @State private var zoomWidth: CGFloat = 320
    @State private var topControlsHeight: CGFloat = 48
    @State private var topControlsWidth: CGFloat = 320
    @State private var lowerControlsHeight: CGFloat = 204
    @AppStorage("shutterDelay") private var shutterDelay = 0
    @AppStorage("centerCrosshair") private var crosshair = false
    @AppStorage("zoomSpeed") private var zoomSpeed = 1.0
    @AppStorage("tapZoomReset") private var tapZoomReset = true
    @AppStorage("recordingLock") private var recordingLock = false
    @AppStorage("gridOpacity") private var gridOpacity = 1.0
    @AppStorage("countdownHaptics") private var countdownHaptics = false
    @AppStorage("recordingStartCountdown") private var recordingStartCountdown = RecordingStartCountdown.off.rawValue
    @AppStorage("audioLevelMeter") private var audioLevelMeter = AudioLevelMeterMode.bars.rawValue
    @AppStorage("cleanPreviewGesture") private var cleanPreviewGesture = CleanPreviewGesture.doubleTap.rawValue
    @AppStorage("mirrorSelfies") private var mirrorSelfies = false
    @AppStorage("zoomButtonsEnabled") private var zoomButtonsEnabled = false
    @AppStorage("liveRecordingStats") private var liveStats = false
    @AppStorage("photoAspect") private var photoAspect = "4:3"
    @AppStorage("longevityMode") private var longevity = false
    @State private var editingStats = false
    @State private var isCleanPreview = false
    @State private var countdownIsForRecording = false
    @State private var restoreBrightness: CGFloat?
    @State private var isPhotoFeedbackVisible = false
    @State private var photoFeedbackTask: Task<Void, Never>?
    private var accent = CameraAccent()

    var body: some View {
        ZStack {
            cameraPreviewLayer
            photoAspectOverlay
            previewGradient
            gridOverlay
            frameGuidesOverlay
            crosshairOverlay
            countdownOverlay
            levelMeterOverlay
            controlsLayer
            proToolsOverlay
            photoFeedbackOverlay
        }
        .overlay {
            if editingStats || (liveStats && camera.isRecording) {
                LiveStatsOverlay(stats: camera.liveStats, editing: editingStats) { editingStats = false }
            }
        }
        .onPreferenceChange(CameraTopControlsHeightKey.self) { height in
            guard height > 0, abs(topControlsHeight - height) > 0.5 else { return }
            topControlsHeight = height
        }
        .onPreferenceChange(CameraLowerControlsHeightKey.self) { height in
            guard abs(lowerControlsHeight - height) > 0.5 else { return }
            lowerControlsHeight = height
        }
        .onChange(of: camera.isRecording) { _, recording in
            AppEventLog.event("Camera UI: recording visible state changed to \(recording)")
            if recording && longevity && camera.captureMode == .video {
                if restoreBrightness == nil { restoreBrightness = UIScreen.main.brightness }
                UIScreen.main.brightness = min(UIScreen.main.brightness, 0.25)
            } else if let brightness = restoreBrightness {
                UIScreen.main.brightness = brightness
                restoreBrightness = nil
            }
        }
        .preferredColorScheme(resolvedColorScheme(appColorScheme))
        .tint(accent.color)
        .task {
            camera.start()
            updateIdleTimer(for: scenePhase)
        }
        .onChange(of: keepScreenAwakeEnabled) { _, _ in
            updateIdleTimer(for: scenePhase)
        }
        .onChange(of: mirrorSelfies) { _, _ in
            camera.refreshMovieOutputSettings()
        }
        .onChange(of: audioLevelMeter) { _, newValue in
            if let mode = AudioLevelMeterMode(rawValue: newValue) {
                camera.setAudioLevelMeterMode(mode)
            }
        }
        .onChange(of: cleanPreviewGesture) { _, newValue in
            if newValue == CleanPreviewGesture.off.rawValue {
                isCleanPreview = false
            }
        }
        .onChange(of: scenePhase) { _, phase in
            updateIdleTimer(for: phase)
            if phase == .active {
                camera.appDidBecomeActive()
                camera.refreshAvailableStorage()
            } else {
                cancelCountdown()
                cancelPhotoFeedback()
                if let brightness = restoreBrightness {
                    UIScreen.main.brightness = brightness
                    restoreBrightness = nil
                }
                camera.appDidBecomeInactive(isBackground: phase == .background)
            }
        }
        .onDisappear {
            cancelCountdown()
            cancelPhotoFeedback()
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
                .preferredColorScheme(resolvedColorScheme(appColorScheme))
                .presentationDetents([.large])
                .presentationDragIndicator(.hidden)
        }
        .onChange(of: camera.captureMode) { _, _ in cancelCountdown() }
        .onChange(of: isShowingSettings) { _, showing in
            if showing { cancelCountdown() }
            AppEventLog.event("Camera UI: Settings sheet \(showing ? "opened" : "closed")")
        }
        .onChange(of: isShowingProTools) { _, showing in
            AppEventLog.event("Camera UI: Pro controls \(showing ? "opened" : "closed")")
        }
    }

    private var cameraPreviewLayer: some View {
        CameraPreview(
            session: camera.session,
            isFocusExposureLocked: camera.isFocusExposureLocked,
            focusExposureLockLabel: camera.focusExposureLockLabel,
            stabilizationEnabled: camera.captureMode == .video && camera.isVideoStabilizationEnabled,
            isPreviewTransitioning: camera.isPreviewTransitioning || camera.isLensTransitioning,
            reservedTopOverlayHeight: (isCleanPreview || !isHUDEnabled)
                ? 54
                : max(54, 14 + topControlsHeight + 8),
            fitsPhoto: camera.captureMode == .photo,
            cleanPreviewGesture: CleanPreviewGesture(rawValue: cleanPreviewGesture) ?? .doubleTap,
            captureOrientation: camera.captureOrientation,
            onTapToFocus: { if !editingStats { camera.focusAndExpose(at: $0) } },
            onLongPressToLock: { if !editingStats { camera.lockFocusAndExposure(at: $0) } },
            onCleanPreviewGesture: {
                guard !editingStats, !isShowingSettings, countdown == 0 else { return }
                withAnimation(.easeOut(duration: 0.18)) {
                    isCleanPreview.toggle()
                }
                CameraHaptics.fire()
                AppEventLog.event("Clean Preview \(isCleanPreview ? "enabled" : "disabled")")
            }
        )
        .ignoresSafeArea()
    }

    @ViewBuilder
    private var photoAspectOverlay: some View {
        if camera.captureMode == .photo && photoAspect == "1:1" {
            GeometryReader { proxy in
                let side = min(proxy.size.width, proxy.size.height)
                VStack(spacing: 0) {
                    Color.black.opacity(0.7)
                    Color.clear.frame(height: side).overlay(Rectangle().stroke(.white.opacity(0.5)))
                    Color.black.opacity(0.7)
                }
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
    }

    private var previewGradient: some View {
        LinearGradient(
            colors: [.black.opacity(0.48), .clear, .black.opacity(0.60)],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var gridOverlay: some View {
        if isGridEnabled {
            CameraGridOverlay(style: GridStyle(rawValue: gridStyle) ?? .ruleOfThirds)
                .opacity(gridOpacity)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var frameGuidesOverlay: some View {
        if frameGuidesEnabled && !isCleanPreview {
            CameraFrameGuideOverlay()
        }
    }

    @ViewBuilder
    private var crosshairOverlay: some View {
        if crosshair {
            Image(systemName: "plus")
                .font(.system(size: 22, weight: .ultraLight))
                .foregroundStyle(.white.opacity(0.7))
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var countdownOverlay: some View {
        if countdown > 0 {
            Button { cancelCountdown() } label: {
                VStack {
                    Text("\(countdown)").font(.system(size: 64, weight: .bold, design: .rounded))
                    Text(countdownIsForRecording ? "Starting recording · tap to cancel" : "Tap to cancel")
                        .font(.caption)
                }
                .padding(24)
                .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 24))
            }
            .foregroundStyle(.white)
            .zIndex(10)
        }
    }

    @ViewBuilder
    private var photoFeedbackOverlay: some View {
        if isPhotoFeedbackVisible {
            Color.white
                .opacity(camera.cameraPosition == .front && frontScreenFlash ? 0.92 : 0.28)
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .transition(.opacity)
                .zIndex(50)
        }
    }

    @ViewBuilder
    private var levelMeterOverlay: some View {
        if isCleanPreview {
            EmptyView()
        } else {
        GeometryReader { proxy in
            let levelHalfExtent: CGFloat = 54
            let topControlsBottom: CGFloat = 14 + topControlsHeight
            let lowerControlsTop = proxy.size.height - 14 - lowerControlsHeight
            let preferredY = proxy.size.height / 2 + 72
            let minimumY = topControlsBottom + levelHalfExtent
            let maximumY = lowerControlsTop - levelHalfExtent
            let hasSafeSpace = maximumY >= minimumY
            let levelY = hasSafeSpace
                ? min(max(preferredY, minimumY), maximumY)
                : max(levelHalfExtent, maximumY)

            CameraLevelMeterHost(
                enabled: isLevelMeterEnabled && !isShowingSettings && hasSafeSpace
            )
            .position(x: proxy.size.width / 2, y: levelY)
        }
        .allowsHitTesting(false)
        }
    }

    private var controlsLayer: some View {
        VStack {
            topControls
            Spacer()
            VStack(spacing: 8) {
                if !isCleanPreview { statusToast }
                bottomControls
            }
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: CameraLowerControlsHeightKey.self,
                        value: proxy.size.height
                    )
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .allowsHitTesting(!editingStats && !camera.isPreviewTransitioning)
    }

    @ViewBuilder
    private var proToolsOverlay: some View {
        if isShowingProTools && !isCleanPreview {
            VStack {
                Spacer()
                HStack {
                    ProToolsPopup(camera: camera, isLevelMeterEnabled: $isLevelMeterEnabled)
                        .allowsHitTesting(true)
                    Spacer()
                }
            }
            .padding(.leading, 14)
            .padding(.bottom, 132)
            // The old full-screen transparent dismiss layer intercepted preview focus and zoom.
            // Dismissal is intentionally owned by the Pro Tools button, leaving the rest of the
            // preview interactive while the popup is open.
            .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottomLeading)))
        }
    }

    @ViewBuilder
    private var topControls: some View {
        if !isCleanPreview {
            let hudMaxWidth = max(120, topControlsWidth - 112)
            let hudSnapshot = CameraHUDSnapshot(
                isRecording: camera.isRecording,
                captureModeLabel: camera.captureMode.rawValue,
                isPhotoMode: camera.captureMode == .photo,
                lensLabel: camera.activeLensLabel,
                resolutionLabel: camera.hudResolutionLabel,
                frameRateLabel: camera.hudFrameRateLabel,
                remainingLabel: camera.hudRemainingLabel,
                whiteBalanceLabel: hudWhiteBalanceLabel,
                audioStatusLabel: camera.audioStatusLabel,
                availableStorageBytes: camera.availableStorageBytes,
                lastFrameGaps: camera.lastFrameGaps
            )

            ZStack(alignment: .top) {
                HStack {
                    if camera.captureMode == .photo {
                        PhotoFlashButton(
                            mode: camera.photoFlashMode,
                            isEnabled: camera.photoFlashAvailable && !camera.isLensTransitioning,
                            color: camera.photoFlashMode == .off ? accent.color.opacity(0.65) : accent.color,
                            action: { camera.cyclePhotoFlashMode() }
                        )
                    } else {
                        TorchButton(camera: camera, isEnabled: !(camera.isRecording && recordingLock))
                    }
                    Spacer()
                    CameraIconButton(
                        symbol: "gearshape.fill",
                        isEnabled: !camera.isRecording && !camera.isRecordingStarting && !camera.isFinalizingRecording && !camera.isCapturingPhoto && !camera.isLensTransitioning,
                        color: accent.color
                    ) {
                        isShowingSettings = true
                    }
                }

                if isHUDEnabled {
                    CameraHUD(
                        snapshot: hudSnapshot,
                        recordingClock: camera.recordingClock,
                        showResolution: hudResolution,
                        showFPS: hudFPS,
                        showRemaining: hudRemaining,
                        showWhiteBalance: hudWhiteBalance,
                        maxWidth: hudMaxWidth,
                        audioMeterMode: camera.audioLevelMeterMode,
                        audioMeterSnapshot: camera.audioMeterSnapshot
                    )
                    // The same 56-point side exclusion used by the old width calculation keeps
                    // the card inside the safe gap between Flash and Settings without a fixed
                    // top-control height.
                    .padding(.horizontal, 56)
                    .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, alignment: .top)
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .preference(key: CameraTopControlsHeightKey.self, value: proxy.size.height)
                        .onAppear { topControlsWidth = proxy.size.width }
                        .onChange(of: proxy.size.width) { _, width in
                            guard abs(topControlsWidth - width) > 0.5 else { return }
                            topControlsWidth = width
                        }
                }
            }
        }
    }

    @ViewBuilder
    private var bottomControls: some View {
        if isCleanPreview {
            shutterRow
        } else {
            normalBottomControls
        }
    }

    private var normalBottomControls: some View {
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

            if zoomButtonsEnabled {
                HStack(spacing: 8) {
                    ForEach(Array(camera.zoomShortcutValues.enumerated()), id: \.offset) { item in
                        let value = item.element
                        Button {
                            CameraHaptics.fire()
                            camera.setZoomFactor(CGFloat(value))
                        } label: {
                            Text(cameraZoomLabel(value))
                                .font(.caption2.weight(.bold).monospacedDigit())
                                .foregroundStyle(abs(camera.zoomFactor - CGFloat(value)) < 0.05 ? accent.color : .white.opacity(0.78))
                                .padding(.horizontal, 9)
                                .padding(.vertical, 5)
                                .background(.black.opacity(0.34), in: Capsule())
                        }
                        .disabled(camera.isRecording && recordingLock)
                        .accessibilityLabel("Set zoom \(cameraZoomLabel(value))")
                    }
                }
                .frame(maxWidth: .infinity)
            }

            CaptureModeSelector(
                selectedMode: camera.captureMode,
                isEnabled: !camera.isRecording && !camera.isRecordingStarting && !camera.isFinalizingRecording && !camera.isCapturingPhoto && !camera.isLensTransitioning && countdown == 0,
                unavailableModes: CameraManager.CaptureMode.allCases.filter { !camera.isCaptureModeSupported($0) },
                onSelect: { camera.selectCaptureMode($0) }
            )
                .padding(.bottom, 8)

            shutterRow
        }
        .padding(.bottom, 8)
    }

    /// One stable shutter row is used in both normal and Clean Preview modes. The side controls
    /// occupy fixed 48-point slots and the pause control uses the left slot beside the centered
    /// shutter while recording, so no offset or overlay can move the shutter when controls change.
    private var shutterRow: some View {
        HStack(spacing: 0) {
            ZStack {
                if camera.isRecording {
                    recordingPauseControl
                } else if !isCleanPreview {
                    CameraIconButton(symbol: "ellipsis", isEnabled: !camera.isRecording && !camera.isRecordingStarting && !camera.isFinalizingRecording && !camera.isCapturingPhoto && !camera.isLensTransitioning && countdown == 0, color: accent.color) {
                        withAnimation(.easeOut(duration: 0.16)) { isShowingProTools.toggle() }
                    }
                }
            }
            .frame(width: ShutterRowLayoutPolicy.sideSlotWidth, height: ShutterRowLayoutPolicy.rowHeight)

            Spacer(minLength: 0)

            ZStack {
                shutterContent
            }
            .frame(width: ShutterRowLayoutPolicy.shutterSlotWidth, height: ShutterRowLayoutPolicy.rowHeight)

            Spacer(minLength: 0)

            ZStack {
                if !camera.isRecording && !isCleanPreview {
                    CameraIconButton(symbol: "camera.rotate", isEnabled: !camera.isRecording && !camera.isRecordingStarting && !camera.isFinalizingRecording && !camera.isCapturingPhoto && !camera.isLensTransitioning && countdown == 0, color: accent.color) {
                        camera.switchCamera()
                    }
                }
            }
            .frame(width: ShutterRowLayoutPolicy.sideSlotWidth, height: ShutterRowLayoutPolicy.rowHeight)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var shutterContent: some View {
        if camera.captureMode == .photo {
            PhotoButton(
                isCapturing: camera.isCapturingPhoto,
                onTap: {
                    guard !editingStats else { return }
                    shutterPressed()
                },
                onBurstStart: {
                    guard !editingStats else { return }
                    cancelCountdown()
                    if camera.captureBurst() {
                        captureHaptic()
                        triggerPhotoFeedback()
                    }
                },
                onBurstEnd: {
                    camera.stopBurst()
                }
            )
        } else if camera.isRecording && recordingLock {
            Image(systemName: "lock.fill")
                .font(.title2)
                .foregroundStyle(accent.color)
                .frame(width: 76, height: 76)
                .background(.black.opacity(0.6), in: Circle())
                .overlay(Circle().stroke(.red, lineWidth: 3))
                .onLongPressGesture(minimumDuration: 1) {
                    CameraHaptics.fire()
                    camera.startOrStopRecording()
                }
                .accessibilityLabel("Recording locked. Hold to stop")
                .accessibilityAction(named: "Stop recording") { camera.startOrStopRecording() }
        } else {
            RecordButton(
                isRecording: camera.isRecording,
                isEnabled: !camera.isRecordingStarting && !camera.isFinalizingRecording && !camera.isLensTransitioning
            ) {
                shutterPressed()
            }
        }
    }

    @ViewBuilder
    private var recordingPauseControl: some View {
        if camera.isRecording && camera.captureMode != .photo {
            RecordingPauseButton(
                isPaused: camera.recordingPauseState == .paused,
                isEnabled: camera.recordingPauseState == .recording || camera.recordingPauseState == .paused
            ) {
                camera.toggleRecordingPause()
            }
        }
    }

    @ViewBuilder
    private var statusToast: some View {
        if let message = camera.statusMessage {
            HStack {
                Spacer(minLength: 0)
                Text(message)
                    .font(.subheadline.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
                    .background(.black.opacity(0.75), in: Capsule())
                    .foregroundStyle(.white)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
            .transition(.opacity)
            .task(id: camera.statusMessageID) {
                let id = camera.statusMessageID
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                camera.clearStatus(id: id)
            }
        }
    }

    private var zoomGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if dragStartZoom == nil {
                    dragStartZoom = camera.zoomFactor
                    camera.beginZoomInteraction()
                    AppEventLog.event("Zoom gesture began at \(camera.zoomLabel)")
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
                    AppEventLog.event("Zoom gesture tapped: reset requested to 1×")
                }
                AppEventLog.event("Zoom gesture ended at \(camera.zoomLabel)")
                camera.endZoomInteraction()
                dragStartZoom = nil
            }
    }

    private func cameraZoomLabel(_ value: Double) -> String {
        abs(value.rounded() - value) < 0.01
            ? "\(Int(value.rounded()))×"
            : String(format: "%.1f×", value)
    }

    private func captureHaptic() {
        guard isHapticsEnabled else { return }
        AppEventLog.event("App haptic requested: capture")
        CameraHaptics.fire()
    }

    private func triggerPhotoFeedback() {
        let isFront = camera.cameraPosition == .front
        let shouldShow = photoCaptureFlash || (isFront && frontScreenFlash)
        guard shouldShow else { return }

        photoFeedbackTask?.cancel()
        isPhotoFeedbackVisible = true
        AppEventLog.event(
            "Photo capture feedback shown: \(isFront && frontScreenFlash ? "front screen flash" : "shutter flash")"
        )
        let duration: UInt64 = isFront && frontScreenFlash ? 180_000_000 : 100_000_000
        photoFeedbackTask = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: duration) } catch { return }
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.16)) {
                isPhotoFeedbackVisible = false
            }
            photoFeedbackTask = nil
        }
    }

    private func cancelPhotoFeedback() {
        photoFeedbackTask?.cancel()
        photoFeedbackTask = nil
        isPhotoFeedbackVisible = false
    }

    private var hudWhiteBalanceLabel: String {
        switch camera.whiteBalancePreset {
        case .auto: return "AWB"
        case .daylight: return "Day"
        case .cloudy: return "Cloud"
        case .tungsten: return "Tung"
        case .fluorescent: return "Fluor"
        case .custom: return "Custom"
        }
    }

    private func cancelCountdown() {
        if countdown > 0 || shutterTask != nil {
            AppEventLog.event("Shutter countdown canceled at \(countdown) seconds remaining")
        }
        shutterTask?.cancel()
        shutterTask = nil
        countdown = 0
        countdownIsForRecording = false
    }

    private func shutterPressed() {
        let mode = camera.captureMode
        let configuredDelay = mode == .photo ? shutterDelay : recordingStartCountdown
        AppEventLog.event("Shutter pressed: mode=\(mode.rawValue), recording=\(camera.isRecording), delay=\(configuredDelay)s")
        if countdown > 0 { cancelCountdown(); return }
        if camera.isRecording { captureHaptic(); camera.startOrStopRecording(); return }
        guard !camera.isRecordingStarting, !camera.isFinalizingRecording,
              shutterTask == nil, camera.isSessionRunning else {
            AppEventLog.event("Shutter ignored: starting=\(camera.isRecordingStarting), finalizing=\(camera.isFinalizingRecording), pendingCountdown=\(shutterTask != nil), sessionRunning=\(camera.isSessionRunning)")
            return
        }
        shutterTask = Task { @MainActor in
            countdownIsForRecording = mode != .photo
            countdown = configuredDelay
            if countdown > 0 {
                AppEventLog.event(
                    "\(mode == .photo ? "Photo shutter timer" : "Recording start countdown") started: \(countdown)s"
                )
            }
            while countdown > 0 {
                if countdownHaptics { CameraHaptics.fire() }
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
                guard !Task.isCancelled else { return }
                countdown -= 1
            }
            guard !Task.isCancelled, scenePhase == .active, camera.captureMode == mode else { return }
            AppEventLog.event("Shutter executing: mode=\(mode.rawValue)")
            if mode == .photo {
                if camera.capturePhoto() {
                    captureHaptic()
                    triggerPhotoFeedback()
                }
            } else {
                captureHaptic()
                camera.startOrStopRecording()
            }
            shutterTask = nil
            countdownIsForRecording = false
        }
    }

    private func updateIdleTimer(for phase: ScenePhase) {
        UIApplication.shared.isIdleTimerDisabled = keepScreenAwakeEnabled && phase == .active
    }

}
