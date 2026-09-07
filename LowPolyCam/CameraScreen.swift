//
//  CameraScreen.swift
//  LowPolyCam
//
//  Updated for iOS 27 / Xcode 27 / Swift 6.4.
//  Swift 6 complete concurrency · Observation · Liquid Glass · RotationCoordinator
//

import SwiftUI
import UIKit
import AVKit

struct CameraScreen: View {

    @ObservedObject var settings: AppSettings
    @ObservedObject var recorder: CameraRecorder

    @State var showSettings = false
    @State var showPlayer = false
    @State var showProMenu = false
    @State var showWhiteBalanceSheet = false
    @State var showGallery = false
    @State var showPhotoReview = false
    @State var reviewedPhotoReviewToken = 0
    @State var dimmed = false
    @State var lastWakeElapsed: TimeInterval = 0
    @State var savedBrightness: CGFloat = UIScreen.main.brightness
    @State var blink = false

    // Countdown State
    @State var countdownRemaining = 0
    @State var countdownTimer: Timer?

    // Zoom
    @State var zoomGestureBase: CGFloat = 1
    @State var isPinching = false
    // True while the user's finger is down on the 1x zoom dial dragging it
    // left/right — separate from `isPinching` (two-finger pinch on the
    // preview) so the two gestures never fight over `zoomGestureBase`.
    @State var isZoomDialDragging = false
    @State var lastRecordButtonTap = Date.distantPast

    // Tap to focus
    @State var focusPoint: CGPoint?
    @State var focusHideToken = 0
    /// True while the reticle shown at `focusPoint` is for a tap-and-hold
    /// lock rather than a plain focus/expose tap — drawn in a different
    /// color so the two moments are visually distinct.
    @State var focusReticleIsLock = false
    /// True for the brief "just landed, still oversized" instant right
    /// after a tap; flips false a beat later to trigger the converge-in
    /// spring. Separate from `focusPoint` so the pop + settle can be its
    /// own two-stage motion instead of one flat fade/scale.
    @State var focusReticleExpanded = true
    /// Drives the slow breathing pulse shown only while a tap-and-hold
    /// lock is active on screen, so a lock visibly reads as "still on"
    /// rather than a static box.
    @State var focusReticlePulsing = false

    // Notice Auto-Dismiss
    @State var noticeHideToken = 0

    // Capture flash confirmation
    @State var showCaptureFlash = false
    /// A short, opaque-enough cover hides AVFoundation's format switch from
    /// the viewfinder instead of exposing a frozen or black frame.
    @State var modeTransitionOpacity: Double = 0
    @State var modeTransitionLabel = ""
    // Sustained screen-illumination for the selfie "flash" — separate from
    // showCaptureFlash above, which is just the brief post-shutter blink.
    @State var screenFlashIlluminating = false
    @State var frontFlashSavedBrightness: CGFloat = UIScreen.main.brightness

    @State var startHaptic = UIImpactFeedbackGenerator(style: .medium)
    @State var stopHaptic = UIImpactFeedbackGenerator(style: .light)
    @State var levelHaptic = UISelectionFeedbackGenerator()
    // Reused instead of created per-render (see zoomControl/modeSelector) —
    // allocating + preparing a new UIFeedbackGenerator on every SwiftUI body
    // re-evaluation is wasted work that adds up on slower A10-class devices.
    @State var zoomHaptic = UISelectionFeedbackGenerator()
    @State var modeHaptic = UISelectionFeedbackGenerator()

    var plan: EncodePlan { Encoder.plan(for: settings) }

    /// Rebuilds the prepared impact-haptic generators at the user's chosen
    /// intensity. `UIImpactFeedbackGenerator`'s style is fixed at init, so
    /// changing intensity means swapping the generator instance rather than
    /// mutating one in place.
    func applyHapticIntensity() {
        startHaptic = UIImpactFeedbackGenerator(style: settings.hapticIntensity.scaled(.medium))
        stopHaptic = UIImpactFeedbackGenerator(style: settings.hapticIntensity.scaled(.light))
        startHaptic.prepare()
        stopHaptic.prepare()
    }

    var body: some View {
        cameraRootView
            .statusBar(hidden: true)
            .tint(settings.accentColor.color)
            .onAppear(perform: handleAppear)
            .onDisappear(perform: handleDisappear)
            .onCameraCaptureEvent(isEnabled: recorder.isSessionRunning && !showSettings && !showGallery
                && !showPhotoReview && !showPlayer && !recorder.isSwitchingMode && !recorder.isSwitchingCamera) { event in
                guard event.phase == .ended else { return }
                switch settings.volumeButtonAction {
                case .shutter: handleShutterTap()
                case .burst: recorder.startBurstCapture()
                case .recording: recorder.toggleRecording()
                }
            }
            .onChange(of: settings.hapticIntensity) { _, _ in
                applyHapticIntensity()
            }
            .onChange(of: recorder.isLevel) { _, isLevel in
                if isLevel && settings.showLevelGauge && settings.hapticFeedbackEnabled {
                    levelHaptic.selectionChanged()
                }
            }
            .onChange(of: recorder.isRecording) { _, isRecording in
                if isRecording { lastWakeElapsed = 0 }
                if !isRecording && dimmed {
                    leaveDim()
                }
            }
            .onChange(of: recorder.elapsed) { _, sec in
                let delay = PerformanceProfile.current(settings: settings).autoDimDelaySeconds
                if settings.autoDimOnRecord && recorder.isRecording && !dimmed && sec - lastWakeElapsed >= delay {
                    enterDim()
                }
            }
            .onChange(of: recorder.notice) { _, newNotice in
                handleNoticeChange(newNotice)
            }
            .onChange(of: showSettings || showPlayer || showGallery || showPhotoReview) { _, isPresented in
                if isPresented {
                    cancelCountdown()
                    recorder.pausePreviewSession()
                } else {
                    recorder.resumePreviewSession()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
                cancelCountdown()
                if screenFlashIlluminating {
                    screenFlashIlluminating = false
                    UIScreen.main.brightness = frontFlashSavedBrightness
                }
                if dimmed { leaveDim() }
            }
            .sheet(isPresented: $showSettings) {
                SettingsScreen(settings: settings, recorder: recorder)
                    .interactiveDismissDisabled(false)
            }
            .sheet(isPresented: $showPlayer) {
                if let url = recorder.lastClipURL {
                    ClipPlayerView(url: url)
                }
            }
            .sheet(isPresented: $showGallery) {
                TabView {
                    PhotoLibraryScreen().tabItem { Label("Photos", systemImage: "photo.on.rectangle") }
                    ClipGalleryScreen(settings: settings).tabItem { Label("Files", systemImage: "folder") }
                }
                .tint(settings.accentColor.color)
            }
            .sheet(isPresented: $showPhotoReview) {
                PhotoReviewScreen(
                    settings: settings,
                    item: recorder.lastPhotoReviewItem,
                    burstItems: recorder.lastBurstReviewItems
                )
            }
            .onChange(of: recorder.photoReviewToken) { _, token in
                guard settings.photoReviewAfterCapture, token != reviewedPhotoReviewToken else { return }
                reviewedPhotoReviewToken = token
                showPhotoReview = true
            }
    }

    var cameraRootView: some View {
        ZStack {
            cameraPreviewLayer

            if recorder.permissionDenied {
                permissionMessage
            } else {
                cameraHUDLayer
            }
        }
    }

    var cameraPreviewLayer: some View {
        ZStack {
            Color.black

            CameraPreview(session: recorder.session, onTap: { [weak recorder] devicePoint, viewPoint in
                if showProMenu {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { showProMenu = false }
                }
                recorder?.focusAndExpose(at: devicePoint)
                showFocusReticle(at: viewPoint, locked: false)
            }, onDoubleTap: { [weak recorder] in
                recorder?.flipCamera()
            }, onLongPress: { [weak recorder] devicePoint, viewPoint in
                guard let recorder else { return }
                if settings.hapticFeedbackEnabled { zoomHaptic.selectionChanged() }
                recorder.lockFocus(at: devicePoint)
                showFocusReticle(at: viewPoint, locked: true)
            }, onTwoFingerLongPress: { [weak recorder] devicePoint, viewPoint in
                guard let recorder else { return }
                if settings.hapticFeedbackEnabled { zoomHaptic.selectionChanged() }
                recorder.lockExposure(at: devicePoint)
                showFocusReticle(at: viewPoint, locked: true)
            })
            .gesture(
                MagnificationGesture()
                    .onChanged { value in
                        if !isPinching {
                            isPinching = true
                            zoomGestureBase = recorder.zoomFactor
                        }
                        recorder.suppressVolumeTriggerBriefly()
                        recorder.setZoom(factor: zoomGestureBase * value)
                    }
                    .onEnded { _ in
                        isPinching = false
                        recorder.suppressVolumeTriggerBriefly()
                    }
            )

            if let focusPoint {
                focusReticle.position(focusPoint)
            }

            if settings.gridStyle != .off { gridOverlay }
            if settings.showLevelGauge { levelGaugeOverlay }
            if countdownRemaining > 0 { countdownOverlay }

            Color.black
                .opacity(recorder.isSwitchingCamera ? 1 : 0)
                .allowsHitTesting(false)
                .animation(.easeInOut(duration: 0.18), value: recorder.isSwitchingCamera)

            Color.black
                .opacity(modeTransitionOpacity)
                .allowsHitTesting(false)
                .overlay(
                    Group {
                        if recorder.isSwitchingMode {
                            Text(modeTransitionLabel)
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                .foregroundColor(.white.opacity(0.9))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Capsule().fill(Palette.slateDeep.opacity(0.8)))
                        }
                    }
                )

            Color.white
                .opacity(showCaptureFlash ? 0.85 : 0)
                .allowsHitTesting(false)
                .animation(.easeOut(duration: 0.18), value: showCaptureFlash)

            Color.white
                .opacity(screenFlashIlluminating ? 1 : 0)
                .allowsHitTesting(false)
                .animation(.easeOut(duration: 0.15), value: screenFlashIlluminating)

            if dimmed { dimOverlay }
        }
        .ignoresSafeArea()
    }

    var cameraHUDLayer: some View {
        ZStack {
            VStack(spacing: 0) {
                topHUD

                if recorder.focusLocked || recorder.exposureLocked {
                    focusExposureLockBar
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .padding(.top, 8)
                }

                if let notice = recorder.notice {
                    noticeBar(notice)
                        .transition(.move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.9)))
                        .padding(.top, 8)
                }

                Spacer(minLength: 0)
                bottomHUD
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            if showProMenu && !recorder.isRecording && !recorder.isSaving {
                Color.black.opacity(0.4)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                            showProMenu = false
                        }
                    }
                    .transition(.opacity)

                VStack {
                    Spacer(minLength: 0)
                    proToolsDrawer
                        .padding(.horizontal, 14)
                        .padding(.bottom, 40)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(20)
                .allowsHitTesting(true)
            }
        }
    }

    func handleAppear() {
        recorder.start()
        applyHapticIntensity()
        startHaptic.prepare()
        stopHaptic.prepare()
        levelHaptic.prepare()
        zoomHaptic.prepare()
        modeHaptic.prepare()
        recorder.onWillCapturePhoto = {
            guard settings.captureFlashConfirmation, recorder.isFrontCamera else { return }
            showCaptureFlash = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                showCaptureFlash = false
            }
        }
    }

    func handleDisappear() {
        if dimmed { leaveDim() }
        recorder.stop()
        countdownTimer?.invalidate()
    }

    func handleNoticeChange(_ newNotice: String?) {
        guard newNotice != nil else { return }
        noticeHideToken += 1
        let token = noticeHideToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            if noticeHideToken == token {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                    recorder.notice = nil
                }
            }
        }
    }

    // MARK: Top HUD Bar

    // Extra tap-target padding for the two most-used top-HUD buttons (flash,
    // settings). Kept as a shared constant so both stay in sync instead of
    // drifting to different inset values.
    let topHUDHitSlop: CGFloat = 18

    var bottomHUD: some View {
        VStack(spacing: 8) {
            // Full-width drag pad (not a small button) so zooming never
            // requires precisely tapping a tiny target — see zoomControl.
            // Hiding this only removes the visible bar; pinch-to-zoom on
            // the preview keeps working regardless.
            if settings.hudShowZoomControl {
                zoomControl
                    .disabled(recorder.isSwitchingCamera || recorder.isSaving)
                    .opacity((recorder.isSwitchingCamera || recorder.isSaving) ? 0.35 : 1)
                    .transition(settings.hudMotion.transition)
            }

            if settings.hudShowModeSelector {
                modeSelector
                    .disabled(recorder.isSwitchingCamera || recorder.isBursting || recorder.isRecording || recorder.isSaving || recorder.isStartingRecording || recorder.isCapturingPhoto)
                    .opacity((recorder.isRecording || recorder.isSaving) ? 0.35 : 1)
                    .frame(maxWidth: .infinity, alignment: .center)
                    // Sit a bit lower above the shutter (same size/design).
                    .padding(.top, 6)
                    .transition(settings.hudMotion.transition)
            }

            ZStack(alignment: .center) {
                // recordButton is centered via ZStack overlay so it stays perfectly
                // centered regardless of asymmetric content in the HStack row below.
                recordButton

                HStack(alignment: .center, spacing: 12) {
                    if settings.hudShowGalleryThumbnail {
                        Group {
                            if !recorder.isRecording && !recorder.isSaving,
                               let thumb = recorder.lastClipThumbnail ?? recorder.lastPhotoThumbnail {
                                Button(action: { showGallery = true }) {
                                    Image(uiImage: thumb)
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                        .frame(width: 44, height: 44)
                                        .clipShape(Facet(sides: 6, rotation: .pi / 6))
                                        .overlay(Facet(sides: 6, rotation: .pi / 6).stroke(settings.accentColor.color.opacity(0.7), lineWidth: 1.5))
                                        .shadow(color: .black.opacity(0.3), radius: 5)
                                }
                                .buttonStyle(.plain)
                                // Same invisible hit-area expansion as the other HUD
                                // icons (see facetButton's hitSlop) — the thumbnail's
                                // visible size stays 44x44, only the tappable area grows.
                                .contentShape(Rectangle().inset(by: -8))
                            } else {
                                facetButton(system: "square.stack.3d.up.fill", size: 44) { showGallery = true }
                                    .disabled(recorder.isRecording || recorder.isSaving)
                                    .opacity((recorder.isRecording || recorder.isSaving) ? 0.35 : 1)
                            }
                        }
                        .transition(settings.hudMotion.transition)
                    }

                    Spacer()

                    // "..." button positioned between shutter and flip-camera button
                    if settings.hudShowProToolsButton, !recorder.isRecording && !recorder.isSaving {
                        Button(action: {
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                                showProMenu.toggle()
                            }
                        }) {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(showProMenu ? settings.accentColor.bright : .white)
                                .frame(width: 36, height: 36)
                                .background(Palette.panel.opacity(0.85))
                                .environment(\.colorScheme, .dark)
                                .clipShape(Circle())
                                .overlay(Circle().stroke(Palette.slateLight.opacity(0.35), lineWidth: 0.8))
                                .shadow(color: .black.opacity(0.2), radius: 4)
                        }
                        .buttonStyle(.plain)
                        .disabled(recorder.isSwitchingCamera)
                        .opacity(recorder.isSwitchingCamera ? 0.35 : 1)
                        .transition(settings.hudMotion.transition)
                    }

                    if recorder.isRecording {
                        // The dim/moon button is a recording control, not a
                        // hideable HUD element — always shown while filming.
                        facetButton(system: "moon.fill", size: 44) { enterDim() }
                    } else if settings.hudShowFlipCameraButton {
                        facetButton(system: "arrow.triangle.2.circlepath.camera.fill", size: 44) {
                            recorder.flipCamera()
                        }
                        .disabled(recorder.isSaving || recorder.isSwitchingCamera || recorder.isCapturingPhoto || recorder.isBursting || countdownRemaining > 0)
                        .opacity((recorder.isSaving || recorder.isSwitchingCamera || recorder.isCapturingPhoto || recorder.isBursting || countdownRemaining > 0) ? 0.35 : 1)
                        .transition(settings.hudMotion.transition)
                    }
                }
                .padding(.horizontal, 4)
            }
        }
        .animation(settings.hudMotion.animation, value: settings.hudShowZoomControl)
        .animation(settings.hudMotion.animation, value: settings.hudShowModeSelector)
        .animation(settings.hudMotion.animation, value: settings.hudShowGalleryThumbnail)
        .animation(settings.hudMotion.animation, value: settings.hudShowProToolsButton)
        .animation(settings.hudMotion.animation, value: settings.hudShowFlipCameraButton)
    }

    var focusExposureLockBar: some View {
        HStack(spacing: 10) {
            if recorder.focusLocked {
                lockChip(label: "AF LOCK", icon: "camera.metering.spot")
            }
            if recorder.exposureLocked {
                lockChip(label: "AE LOCK", icon: "sun.max.fill")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(Palette.panel.opacity(0.9))
                .background(Capsule().fill(Palette.slateDeep.opacity(usesLightweightMaterial ? 0.55 : 0.3)))
        )
        .overlay(Capsule().stroke(Palette.amber.opacity(0.5), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 10, x: 0, y: 4)
        .onTapGesture {
            if settings.hapticFeedbackEnabled { levelHaptic.selectionChanged() }
            if recorder.focusLocked { recorder.unlockFocus() }
            if recorder.exposureLocked { recorder.unlockExposure() }
        }
    }

    func lockChip(label: String, icon: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .bold))
            Image(systemName: "lock.fill")
                .font(.system(size: 8, weight: .bold))
            Text(label)
                .font(.system(size: 11, weight: .black, design: .rounded))
        }
        .foregroundColor(Palette.slateDeep)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(Palette.amber))
    }

    func noticeBar(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(settings.accentColor.bright)

            Text(text)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundColor(.white.opacity(0.95))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(
            Capsule()
                .fill(Palette.panel.opacity(0.9))
                .background(Capsule().fill(Palette.slateDeep.opacity(usesLightweightMaterial ? 0.55 : 0.3)))
        )
        .overlay(
            Capsule()
                .stroke(settings.accentColor.bright.opacity(0.45), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.4), radius: 12, x: 0, y: 5)
        .onTapGesture {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                recorder.notice = nil
            }
        }
    }

    var permissionMessage: some View {
        VStack(spacing: 18) {
            ZStack {
                Facet(sides: 6, rotation: .pi / 6)
                    .fill(settings.accentColor.color.opacity(0.2))
                    .frame(width: 80, height: 80)
                Image(systemName: "camera.fill")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundColor(settings.accentColor.bright)
            }
            .shadow(color: settings.accentColor.color.opacity(0.4), radius: 16)

            Text("Camera access is off")
                .font(.system(size: 20, weight: .bold, design: .rounded))
            Text("Turn it on in Settings › LowPolyCam.")
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.white.opacity(0.65))
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .font(.system(size: 15, weight: .bold, design: .rounded))
            .foregroundColor(Palette.slateDeep)
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
            .background(
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [settings.accentColor.bright, settings.accentColor.color],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .shadow(color: settings.accentColor.color.opacity(0.4), radius: 8, y: 3)
            .padding(.top, 6)
        }
        .foregroundColor(.white)
        .padding(36)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(Palette.panel.opacity(0.92))
                .background(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .fill(Palette.slateDeep.opacity(usesLightweightMaterial ? 0.55 : 0.3))
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color.white.opacity(0.1), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.45), radius: 28, x: 0, y: 14)
    }

    // MARK: Zoom & Focus

    var gridOverlay: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            Path { path in
                switch settings.gridStyle {
                case .off:
                    break
                case .thirds:
                    for i in 1...2 {
                        let x = w * CGFloat(i) / 3
                        path.move(to: CGPoint(x: x, y: 0))
                        path.addLine(to: CGPoint(x: x, y: h))
                        let y = h * CGFloat(i) / 3
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: w, y: y))
                    }
                case .crosshair:
                    path.move(to: CGPoint(x: w / 2, y: 0))
                    path.addLine(to: CGPoint(x: w / 2, y: h))
                    path.move(to: CGPoint(x: 0, y: h / 2))
                    path.addLine(to: CGPoint(x: w, y: h / 2))
                case .square:
                    let side = min(w, h) * 0.72
                    let rect = CGRect(x: (w - side) / 2, y: (h - side) / 2, width: side, height: side)
                    path.addRect(rect)
                    // center cross ticks
                    let tick: CGFloat = 12
                    path.move(to: CGPoint(x: w / 2 - tick, y: h / 2))
                    path.addLine(to: CGPoint(x: w / 2 + tick, y: h / 2))
                    path.move(to: CGPoint(x: w / 2, y: h / 2 - tick))
                    path.addLine(to: CGPoint(x: w / 2, y: h / 2 + tick))
                }
            }
            .stroke(Color.white.opacity(0.28), lineWidth: 0.7)
        }
        .allowsHitTesting(false)
    }

    // MARK: Zoom dial (drag-to-zoom, like the native Camera app's "1x" pill)

    /// Hard ceiling for the drag gesture, per spec — independent of whatever
    /// `recorder.maxZoomFactor` the hardware reports, then clamped to it so
    /// we never ask the session for more zoom than the lens can deliver.
    let zoomDialMaxFactor: CGFloat = 8
    var zoomDialMinFactor: CGFloat { max(0.5, recorder.minZoomFactor) }

    func zoomDialLabel(_ factor: CGFloat) -> String {
        if abs(factor - factor.rounded()) < 0.05 {
            return "\(Int(factor.rounded()))x"
        }
        return String(format: "%.1fx", factor)
    }

    /// A full-width invisible drag pad (not a tiny button) so you never have
    /// to land your finger precisely on the "1x" pill to zoom — touch down
    /// and drag ANYWHERE across this bar. Sensitivity is derived from the
    /// pad's actual measured width so that swiping from the center out to
    /// either edge always covers the complete 1x–8x range, regardless of
    /// screen size. A tap that doesn't move never changes the zoom — only
    /// dragging does, so an accidental tap never resets your zoom.
    var zoomControl: some View {
        SingleZoomControl(value: recorder.zoomFactor,
                          minimum: zoomDialMinFactor,
                          maximum: recorder.maxZoomFactor,
                          enabled: recorder.isSessionRunning && !recorder.isSwitchingMode
                            && !recorder.isSwitchingCamera && !recorder.isCapturingPhoto
                            && !recorder.isSaving && !recorder.isStartingRecording,
                          change: { recorder.setZoom(factor: $0) },
                          reset: { recorder.setZoom(factor: 1, resetToWide: true) })
    }

    var focusReticle: some View {
        let reticleColor = focusReticleIsLock ? Palette.amber : settings.accentColor.bright
        // Settled scale is 1.0, plus a slow ±6% breathing pulse only while
        // a lock is actively held on screen — a plain focus tap never pulses.
        let settledScale: CGFloat = (focusReticleIsLock && focusReticlePulsing) ? 1.06 : 1.0
        return ZStack {
            // Thin square outline — classic camera-app focus box, not a hexagon.
            // Slightly thicker for that first "just landed" instant, thinning
            // as it settles, mirroring how stock camera apps snap a focus box in.
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .stroke(reticleColor, lineWidth: focusReticleExpanded ? 1.8 : 1.2)
                .frame(width: 64, height: 64)

            // Small corner tick marks for that "locking on" feel.
            ForEach(0..<4) { i in
                Rectangle()
                    .fill(reticleColor)
                    .frame(width: 8, height: 2)
                    .offset(x: (i % 2 == 0 ? -1 : 1) * 28, y: (i < 2 ? -1 : 1) * 32)
            }

            // Small center dot to mark the exact focus point.
            Circle()
                .fill(reticleColor)
                .frame(width: 4, height: 4)

            // A small padlock badge on top-right of the box for tap-and-hold
            // locks, so the reticle itself communicates "locked" without
            // needing to read the AF/AE pill elsewhere on screen.
            if focusReticleIsLock {
                Image(systemName: "lock.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(Palette.slateDeep)
                    .padding(3)
                    .background(Circle().fill(reticleColor))
                    .offset(x: 30, y: -30)
            }
        }
        .shadow(color: reticleColor.opacity(focusReticleExpanded ? 0.7 : 0.4), radius: focusReticleExpanded ? 8 : 3)
        // Two-stage motion: the box pops in slightly oversized (a snappy
        // "acquired" moment), then converges to its resting size a beat
        // later — closer to how stock camera apps animate focus acquisition
        // than a single flat fade. `focusPoint == nil` still governs the
        // overall appear/disappear so it fades out from wherever it was.
        .scaleEffect(focusPoint == nil ? 1.4 : (focusReticleExpanded ? 1.25 : settledScale))
        .opacity(focusPoint == nil ? 0 : 1)
        .animation(.spring(response: 0.32, dampingFraction: 0.62), value: focusReticleExpanded)
        .animation(.easeInOut(duration: 0.9), value: focusReticlePulsing)
        .animation(.spring(response: 0.26, dampingFraction: 0.7), value: focusPoint)
    }

    func showFocusReticle(at point: CGPoint, locked: Bool) {
        focusHideToken += 1
        let token = focusHideToken
        focusReticleIsLock = locked
        focusReticleExpanded = true
        focusReticlePulsing = false
        focusPoint = point

        // Let the oversized "just landed" frame render for one beat, then
        // converge to resting size — the pop-then-settle read that makes a
        // focus acquisition feel deliberate rather than just a fade-in box.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            guard focusHideToken == token else { return }
            focusReticleExpanded = false
            if locked {
                // Continuous gentle pulse for as long as the lock reticle
                // stays visible, so an active lock visibly reads as "on".
                withAnimation(Animation.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    focusReticlePulsing = true
                }
            }
        }

        // Give a lock confirmation a beat longer on screen than a plain
        // focus tap, since it's confirming a mode change, not just a spot.
        let holdDuration: Double = locked ? 1.3 : 0.9
        DispatchQueue.main.asyncAfter(deadline: .now() + holdDuration) {
            if focusHideToken == token {
                focusPoint = nil
                focusReticlePulsing = false
            }
        }
    }

    // MARK: Dim Mode

    var dimOverlay: some View {
        Color.black
            .ignoresSafeArea()
            .overlay(
                VStack(spacing: 12) {
                    Facet(sides: 6)
                        .fill(Palette.record)
                        .frame(width: 12, height: 12)
                        .shadow(color: Palette.record, radius: blink ? 6 : 0)
                        .opacity(blink ? 0.3 : 1)
                        .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: blink)

                    Text("recording · tap to wake")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.2))
                }
            )
            .onTapGesture { leaveDim() }
    }

    func enterDim() {
        guard !dimmed else { return }
        if UIScreen.main.brightness > 0.05 {
            savedBrightness = UIScreen.main.brightness
        }
        UIScreen.main.brightness = 0
        withAnimation(.easeIn(duration: 0.3)) { dimmed = true }
    }

    func leaveDim() {
        guard dimmed else { return }
        lastWakeElapsed = recorder.elapsed
        let target = savedBrightness > 0.05 ? savedBrightness : 0.5
        UIScreen.main.brightness = target
        withAnimation(.easeOut(duration: 0.2)) { dimmed = false }
    }
}

// MARK: - In-App Video Preview Player

struct ClipPlayerView: View {
    let url: URL
    @Environment(\.dismiss) var dismiss
    @State var player: AVPlayer?
    @State var loadFailed = false

    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()
                if let player, !loadFailed {
                    VideoPlayer(player: player)
                        .ignoresSafeArea(edges: .bottom)
                } else if loadFailed {
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 40))
                            .foregroundColor(Palette.amber)
                            .shadow(color: Palette.amber.opacity(0.5), radius: 10)
                        Text("Unable to play video preview")
                            .font(.headline)
                            .foregroundColor(.white)
                        Text("The clip file could not be found or opened.")
                            .font(.subheadline)
                            .foregroundColor(.white.opacity(0.6))
                    }
                    .padding()
                } else {
                    ProgressView().tint(Palette.violet.opacity(0.95)).scaleEffect(1.2)
                }
            }
            .navigationTitle("Preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        player?.pause()
                        dismiss()
                    }
                }
            }
        }
        .tint(Palette.violet)
        .onAppear {
            guard FileManager.default.fileExists(atPath: url.path) else {
                loadFailed = true
                return
            }
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [])
            let p = AVPlayer(url: url)
            player = p
            p.play()
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }
}
