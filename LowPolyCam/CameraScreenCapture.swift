import SwiftUI
import UIKit

extension CameraScreen {

    func handleShutterTap() {
        guard recorder.isSessionRunning, !recorder.isSwitchingMode, !recorder.isStartingRecording,
              !screenFlashIlluminating, !recorder.isSwitchingCamera, !isPinching,
              !recorder.isCapturingPhoto, !recorder.isSaving else { return }
        let now = Date()
        guard now.timeIntervalSince(lastRecordButtonTap) > 0.4 else { return }
        lastRecordButtonTap = now

        if settings.cameraMode == .photo {
            if recorder.isBursting {
                recorder.cancelBurstCapture()
                return
            }
            if countdownRemaining > 0 {
                cancelCountdown()
            } else if settings.countdownTimer != .off {
                startCountdown()
            } else {
                triggerPhotoCapture()
            }
            return
        }

        if recorder.isRecording {
            if settings.hapticFeedbackEnabled {
                stopHaptic.impactOccurred()
                stopHaptic.prepare()
            }
            if dimmed { leaveDim() }
            recorder.toggleRecording()
        } else {
            if countdownRemaining > 0 {
                cancelCountdown()
            } else if settings.countdownTimer != .off {
                startCountdown()
            } else {
                if settings.hapticFeedbackEnabled {
                    startHaptic.impactOccurred()
                    startHaptic.prepare()
                }
                recorder.toggleRecording()
            }
        }
    }

    /// Photo-mode press-and-hold → burst mode. Only armed in Photo mode,
    /// outside a countdown, with nothing else already in flight — a plain
    /// tap still falls through to `handleShutterTap()` via the Button below,
    /// so short presses behave exactly as before and nothing shifts.
    func handleShutterLongPress() {
        guard settings.cameraMode == .photo,
              countdownRemaining == 0,
              !recorder.isBursting,
              !recorder.isCapturingPhoto,
              !recorder.isSaving,
              !recorder.isSwitchingCamera else { return }
        if settings.hapticFeedbackEnabled {
            startHaptic.impactOccurred()
            startHaptic.prepare()
        }
        recorder.startBurstCapture()
    }

    var recordButton: some View {
        Button(action: handleShutterTap) {
            ZStack {
                // Soft outer glow
                Facet(sides: 12)
                    .fill(settings.accentColor.color.opacity(0.18))
                    .frame(width: 82, height: 82)
                    .blur(radius: 8)

                // Outer ring
                Facet(sides: 12)
                    .stroke(
                        LinearGradient(
                            colors: [settings.accentColor.bright, settings.accentColor.deep],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 3.5
                    )
                    .frame(width: 76, height: 76)
                    .shadow(color: settings.accentColor.color.opacity(0.45), radius: 10)

                // Burst-mode progress ring — fills in as frames are captured,
                // drawn just inside the outer ring so it never changes the
                // button's footprint or nudges neighboring HUD icons.
                if recorder.isBursting && recorder.burstShotsTotal > 0 {
                    Circle()
                        .trim(from: 0, to: CGFloat(recorder.burstShotsTaken) / CGFloat(recorder.burstShotsTotal))
                        .stroke(Palette.record, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                        .frame(width: 76, height: 76)
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 0.1), value: recorder.burstShotsTaken)
                }

                // Inner track
                Facet(sides: 12)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1.5)
                    .frame(width: 66, height: 66)

                if recorder.isBursting {
                    // Burst counter takes over the center glyph while firing —
                    // same visual weight/position as the other center states
                    // below, so the button never appears to resize.
                    Text("\(recorder.burstShotsTaken)/\(recorder.burstShotsTotal)")
                        .font(.system(size: 13, weight: .black, design: .rounded))
                        .foregroundColor(.white)
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(Palette.record.opacity(0.85)))
                } else if recorder.isSaving || recorder.isCapturingPhoto {
                    // At 120/240fps finishWriting has a lot more to flush than at
                    // 30/60fps (no movie fragments at 240fps, far more frames
                    // encoded), so this spinner can sit here for a couple of
                    // seconds on a long slow-mo clip. A bare spinner in that case
                    // reads as the app being stuck — the ring animation makes it
                    // clear something is still actively happening.
                    ProgressView().tint(settings.accentColor.bright).scaleEffect(1.25)
                        .overlay(
                            Circle()
                                .stroke(settings.accentColor.bright.opacity(0.35), lineWidth: 2)
                                .frame(width: 60, height: 60)
                                .rotationEffect(.degrees(blink ? 360 : 0))
                                .animation(.linear(duration: 1.1).repeatForever(autoreverses: false), value: blink)
                        )
                } else if recorder.isRecording {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Palette.record, Palette.record.opacity(0.82)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(width: 30, height: 30)
                        .shadow(color: Palette.record.opacity(0.7), radius: 12)
                } else if countdownRemaining > 0 {
                    Image(systemName: "xmark")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(.white)
                } else {
                    Facet(sides: 12)
                        .fill(
                            LinearGradient(
                                colors: [Color.white, Color.white.opacity(0.9)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 54, height: 54)
                        .shadow(color: Color.white.opacity(0.4), radius: 6, x: 0, y: 2)
                        .overlay(
                            Facet(sides: 12)
                                .stroke(Color.black.opacity(0.06), lineWidth: 1)
                                .frame(width: 54, height: 54)
                        )
                }
            }
            .frame(width: 82, height: 82)
        }
        .buttonStyle(.plain)
        // Visual size stays 82 (ring is 76pt); expand the touch target a bit
        // further than before so it's comfortably larger than the visible
        // colored ring on every side.
        .frame(width: 118, height: 118)
        .contentShape(Circle())
        .disabled(recorder.isSaving || recorder.isSwitchingCamera || recorder.isCapturingPhoto)
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: recorder.isRecording)
        // Press-and-hold for burst mode, photo mode only. Uses a plain
        // LongPressGesture (not `.sequenced`) alongside the Button above —
        // SwiftUI dispatches the Button's tap action only when this gesture
        // does not itself consume the touch as a completed long-press, so a
        // quick tap still reaches handleShutterTap() unchanged.
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.45)
                .onEnded { _ in handleShutterLongPress() }
        )
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onEnded { _ in
                    if recorder.isBursting { recorder.cancelBurstCapture() }
                }
        )
    }

    var modeSelector: some View {
        let modes = CameraMode.allCases

        return HStack(spacing: 2) {
            ForEach(modes) { mode in
                let isActive = settings.cameraMode == mode
                Button {
                    guard settings.cameraMode != mode else { return }
                    let previous = settings.cameraMode
                    DebugLog.write("modeSelector: \(previous) -> \(mode)")
                    if settings.hapticFeedbackEnabled { modeHaptic.selectionChanged() }
                    switchCaptureMode(to: mode)
                } label: {
                    Text(mode.label)
                        .font(.system(size: 13, weight: isActive ? .bold : .semibold, design: .rounded))
                        .foregroundColor(isActive ? Palette.slateDeep : .white.opacity(0.72))
                        // Fixed horizontal padding keeps the control the same
                        // width across modes so it never expands/clips at edges.
                        .frame(minWidth: 58)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(
                            Group {
                                if isActive {
                                    Capsule()
                                        .fill(
                                            LinearGradient(
                                                colors: [settings.accentColor.bright, settings.accentColor.color],
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing
                                            )
                                        )
                                        .shadow(color: settings.accentColor.color.opacity(0.4), radius: 4, y: 2)
                                }
                            }
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(
            Capsule()
                .fill(Palette.panel.opacity(0.88))
                .background(Capsule().fill(Palette.slateDeep.opacity(usesLightweightMaterial ? 0.55 : 0.3)))
        )
        .overlay(
            Capsule()
                .stroke(
                    LinearGradient(
                        colors: [Color.white.opacity(0.16), Color.white.opacity(0.04)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        .shadow(color: .black.opacity(0.35), radius: 12, x: 0, y: 6)
        // Centered, never forced wider than content so it stays clear of screen edges.
        .frame(maxWidth: .infinity, alignment: .center)
    }

    func switchCaptureMode(to mode: CameraMode) {
        guard !recorder.isSwitchingMode,
              mode != settings.cameraMode,
              !recorder.isStartingRecording,
              !recorder.isSwitchingCamera,
              !recorder.isCapturingPhoto,
              !recorder.isRecording,
              !recorder.isSaving,
              !recorder.isBursting else { return }

        recorder.isSwitchingMode = true
        modeTransitionLabel = mode.label
        withAnimation(.easeOut(duration: 0.12)) {
            modeTransitionOpacity = 1
        }

        // The cover is already opaque in this transaction. Start configuring
        // next run-loop instead of paying a fixed delay on every mode tap.
        DispatchQueue.main.async {
            recorder.activeSensorFPS = 0
            settings.cameraMode = mode
            recorder.updateCaptureFormat {
                DispatchQueue.main.async {
                    withAnimation(.easeIn(duration: 0.14)) {
                        modeTransitionOpacity = 0
                    }
                    recorder.isSwitchingMode = false
                }
            }
        }
    }

    func facetButton(system: String,
                             size: CGFloat = 40,
                             tint: Color = .white,
                             hitSlop: CGFloat = 8,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: size * 0.36, weight: .semibold))
                .foregroundColor(tint)
                .frame(width: size, height: size)
                .background(
                    Facet(sides: 6, rotation: .pi / 6)
                        .fill(Palette.panel.opacity(0.88))
                        .background(
                            Facet(sides: 6, rotation: .pi / 6)
                                .fill(Palette.slateDeep.opacity(usesLightweightMaterial ? 0.55 : 0.3))
                        )
                )
                .overlay(
                    Facet(sides: 6, rotation: .pi / 6)
                        .stroke(
                            LinearGradient(
                                colors: [Color.white.opacity(0.22), Color.white.opacity(0.06)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                )
                .shadow(color: .black.opacity(0.4), radius: 10, x: 0, y: 5)
        }
        .buttonStyle(.plain)
        // Negative inset grows the TAPPABLE area on every side without
        // changing the button's actual layout size — neighboring buttons don't shift.
        // hitSlop is per-caller so the most-reached-for buttons (flash, settings)
        // can get an even bigger invisible hit area than the default.
        .contentShape(Rectangle().inset(by: -hitSlop))
    }

    // MARK: Overlays (Level Meter & Countdown)

    var levelGaugeOverlay: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let isLevel = recorder.isLevel

            ZStack {
                Circle()
                    .stroke(isLevel ? settings.accentColor.bright : Color.white.opacity(0.3), lineWidth: 1.5)
                    .frame(width: 12, height: 12)

                HStack(spacing: 24) {
                    Rectangle()
                        .fill(isLevel ? settings.accentColor.bright : Color.white.opacity(0.3))
                        .frame(width: 40, height: 1.5)

                    Spacer().frame(width: 12)

                    Rectangle()
                        .fill(isLevel ? settings.accentColor.bright : Color.white.opacity(0.3))
                        .frame(width: 40, height: 1.5)
                }
                .rotationEffect(.degrees(-recorder.rollAngle))
                .animation(.spring(response: 0.15, dampingFraction: 0.8), value: recorder.rollAngle)
            }
            .position(x: w / 2, y: h / 2)
            .shadow(color: isLevel ? settings.accentColor.color.opacity(0.6) : .clear, radius: 4)
        }
        .allowsHitTesting(false)
    }

    var countdownOverlay: some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()

            VStack(spacing: 8) {
                Text("\(countdownRemaining)")
                    .font(.system(size: 84, weight: .black, design: .rounded))
                    .foregroundColor(settings.accentColor.bright)
                    .shadow(color: settings.accentColor.color.opacity(0.6), radius: 20)
                    .scaleEffect(1.1)
                    .animation(.spring(response: 0.3, dampingFraction: 0.6), value: countdownRemaining)

                Text("Tap shutter to cancel")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white.opacity(0.7))
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Photo capture (routes selfie flash through screen illumination)

    func triggerPhotoCapture() {
        if recorder.isFrontCamera && recorder.frontFlashEnabled {
            performFrontFlashCapture()
        } else {
            recorder.capturePhoto()
        }
    }

    func performFrontFlashCapture() {
        guard !screenFlashIlluminating else { return }
        frontFlashSavedBrightness = UIScreen.main.brightness
        UIScreen.main.brightness = 1.0
        screenFlashIlluminating = true

        // Restore brightness only after the sensor actually fires
        // (onWillCapturePhoto), not on a fixed timer after capturePhoto() —
        // on A10 the capture can land later than 0.12s and underexpose.
        let previousHook = recorder.onWillCapturePhoto
        recorder.onWillCapturePhoto = {
            previousHook?()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                screenFlashIlluminating = false
                UIScreen.main.brightness = frontFlashSavedBrightness
                recorder.onWillCapturePhoto = previousHook
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            guard screenFlashIlluminating, recorder.isSessionRunning,
                  !recorder.isSwitchingMode, !recorder.isSwitchingCamera else {
                recorder.onWillCapturePhoto = previousHook
                return
            }
            recorder.capturePhoto()
            // Safety: if willCapture never fires, still restore after 2s.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                if screenFlashIlluminating {
                    screenFlashIlluminating = false
                    UIScreen.main.brightness = frontFlashSavedBrightness
                    recorder.onWillCapturePhoto = previousHook
                }
            }
        }
    }

    func startCountdown() {
        let mode = settings.cameraMode
        let front = recorder.isFrontCamera
        countdownRemaining = settings.countdownTimer.rawValue
        let haptic = UIImpactFeedbackGenerator(style: settings.hapticIntensity.scaled(.heavy))
        haptic.prepare()

        countdownTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0, repeats: true) { _ in
            guard recorder.isSessionRunning, settings.cameraMode == mode,
                  recorder.isFrontCamera == front, !showSettings, !showGallery,
                  !recorder.isSwitchingMode, !recorder.isSwitchingCamera else { cancelCountdown(); return }
            if settings.hapticFeedbackEnabled { haptic.impactOccurred() }
            if countdownRemaining > 1 {
                countdownRemaining -= 1
            } else {
                countdownTimer?.invalidate()
                countdownTimer = nil
                countdownRemaining = 0
                guard !recorder.isSwitchingCamera, !recorder.isSaving else { return }
                if settings.cameraMode == .photo {
                    triggerPhotoCapture()
                } else {
                    if settings.hapticFeedbackEnabled { startHaptic.impactOccurred() }
                    recorder.startRecording()
                }
            }
        }
        // Common modes so the countdown keeps ticking during scroll/drag.
        RunLoop.main.add(timer, forMode: .common)
        countdownTimer = timer
    }

    func cancelCountdown() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        countdownRemaining = 0
    }

    /// Persistent "what's locked" pill — stays up the whole time a lock is
    /// active (unlike the reticle flash, which fades in ~1s), since AF/AE
    /// lock can otherwise be a silent state that's easy to forget is on and
    /// then blame for a blurry/blown-out shot. Tapping either badge (or the
    /// whole pill) releases both locks and returns to continuous AF/AE.
}
