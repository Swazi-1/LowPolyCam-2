import SwiftUI
import UIKit

extension CameraScreen {

    var topHUD: some View {
        HStack(alignment: .center, spacing: 8) {
            Group {
                if settings.hudShowFlashButton, recorder.hasTorch {
                    facetButton(system: recorder.torchOn ? "bolt.fill" : "bolt.slash.fill",
                                size: 40,
                                tint: recorder.torchOn ? settings.accentColor.bright : .white,
                                hitSlop: topHUDHitSlop) {
                        recorder.toggleTorch()
                    }
                    .transition(settings.hudMotion.transition)
                } else if settings.hudShowFlashButton, recorder.isFrontCamera, settings.cameraMode == .photo {
                    // No physical torch on the front camera — this toggles the
                    // screen-illumination flash used at capture time instead
                    // (see performFrontFlashCapture), same idea as stock Camera.
                    facetButton(system: recorder.frontFlashEnabled ? "bolt.fill" : "bolt.slash.fill",
                                size: 40,
                                tint: recorder.frontFlashEnabled ? settings.accentColor.bright : .white,
                                hitSlop: topHUDHitSlop) {
                        recorder.frontFlashEnabled.toggle()
                        if settings.hapticFeedbackEnabled { levelHaptic.selectionChanged() }
                    }
                    .transition(settings.hudMotion.transition)
                } else {
                    // Keep layout balanced whether hidden by the HUD setting
                    // or genuinely unavailable on this lens.
                    Color.clear.frame(width: 40, height: 40)
                }
            }

            Spacer(minLength: 4)

            Group {
                if settings.hudShowInfoPill {
                    compactInfoPill
                        // Let the actual safe-area width distribute space. This
                        // stays centered on iPhone 11/Pro/Max instead of using a
                        // process-wide UIScreen measurement.
                        .frame(maxWidth: .infinity)
                        .layoutPriority(1)
                        .transition(settings.hudMotion.transition)
                }
            }

            Spacer(minLength: 4)

            // Always visible — hiding the way back into Settings would
            // strand anyone who hides other HUD elements from here.
            facetButton(system: "gearshape.fill", size: 40, hitSlop: topHUDHitSlop) { showSettings = true }
                .disabled(recorder.isRecording || recorder.isSaving || recorder.isSwitchingCamera || recorder.isBursting)
                .opacity((recorder.isRecording || recorder.isSaving || recorder.isSwitchingCamera || recorder.isBursting) ? 0.35 : 1)
        }
        .animation(settings.hudMotion.animation, value: settings.hudShowFlashButton)
        .animation(settings.hudMotion.animation, value: settings.hudShowInfoPill)
    }

    var dataRateLabel: String {
        let mb = plan.megabytesPerHour
        if mb >= 1000 {
            return String(format: "%.1f GB/h", mb / 1000.0)
        } else {
            return "\(Int(mb.rounded())) MB/h"
        }
    }

    var qualityShortLabel: String {
        switch settings.quality {
        case .high: return "High"
        case .medium: return "Med"
        case .low: return "Low"
        case .ultraLow: return "Saver"
        }
    }

    /// Whether the pill's "~X h/min left" estimate should render this frame
    /// — its own toggle, storage-derived data available, and not Photo mode
    /// (a photo count estimate would need a different formula entirely).
    var showsTimeRemainingInPill: Bool {
        settings.hudShowTimeRemaining && settings.cameraMode != .photo && plan.megabytesPerHour > 0
    }

    var compactInfoPill: some View {
        // Precomputed once per render so the separator dots between pill
        // segments below can each ask "did anything before me render?"
        // without repeating these conditions inline.
        let showStorage = settings.hudShowStorageInfo
        let showTimeRemaining = showsTimeRemainingInPill
        let showBattery = settings.hudShowBatteryInfo && recorder.batteryPercent >= 0
        let showThermal = recorder.thermalState != .nominal && recorder.thermalState != .fair

        return VStack(spacing: 3) {
            if recorder.isRecording || recorder.isSaving {
                recordingStatusRow
            } else {
                HStack(spacing: 5) {
                    if settings.cameraMode == .photo {
                        Text("PHOTO")
                            .font(.system(size: 10, weight: .black, design: .rounded))
                            .foregroundColor(Palette.slateDeep)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2.5)
                            .background(settings.accentColor.bright)
                            .clipShape(Capsule())

                        if settings.hudShowMegapixels {
                            Text(settings.photoMegapixels.label)
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                .foregroundColor(.white.opacity(0.92))
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                        }

                        if recorder.isCapturingPhoto {
                            ProgressView().tint(settings.accentColor.bright).scaleEffect(0.6)
                        }
                    } else if settings.cameraMode == .slowMo {
                        Text("SLO-MO")
                            .font(.system(size: 10, weight: .black, design: .rounded))
                            .foregroundColor(Palette.slateDeep)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2.5)
                            .background(settings.accentColor.bright)
                            .clipShape(Capsule())

                        let sensorFPS = recorder.activeSensorFPS >= 100
                            ? Int(recorder.activeSensorFPS.rounded())
                            : settings.slowMoFrameRate.value
                        Text("\(sensorFPS) fps")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundColor(abs(Double(sensorFPS - settings.slowMoFrameRate.value)) <= 1
                                             ? .white : Palette.warning)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    } else {
                        Text("VIDEO")
                            .font(.system(size: 10, weight: .black, design: .rounded))
                            .foregroundColor(Palette.slateDeep)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2.5)
                            .background(
                                LinearGradient(
                                    colors: [settings.accentColor.bright, settings.accentColor.color],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .clipShape(Capsule())

                        Text("\(settings.resolution.label) · \(settings.frameRate.label)")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundColor(.white.opacity(0.92))
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }

                    if settings.cameraMode != .photo {
                        Text("·")
                            .foregroundColor(Palette.slateLight)
                            .font(.system(size: 11, weight: .bold))

                        Text(dataRateLabel)
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(settings.accentColor.bright)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                }
                .lineLimit(1)

                HStack(spacing: 5) {
                    if showStorage {
                        HStack(spacing: 3) {
                            Image(systemName: "internaldrive")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(Palette.slateLight)
                            Text(Fmt.size(recorder.freeBytes) + " free")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.white.opacity(0.68))
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                    }

                    if showTimeRemaining {
                        let hoursLeft = Double(max(0, recorder.freeBytes - 300_000_000)) / 1_000_000.0 / plan.megabytesPerHour
                        if showStorage {
                            Text("·")
                                .foregroundColor(Palette.slateLight)
                                .font(.system(size: 11, weight: .bold))
                        }
                        HStack(spacing: 3) {
                            Image(systemName: "clock")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(Palette.slateLight)
                            Text("~" + Fmt.hours(hoursLeft))
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.white.opacity(0.68))
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                    }

                    if showBattery {
                        if showStorage || showTimeRemaining {
                            Text("·")
                                .foregroundColor(Palette.slateLight)
                                .font(.system(size: 11, weight: .bold))
                        }
                        batteryIndicator
                    }

                    if showThermal {
                        if showStorage || showTimeRemaining || showBattery {
                            Text("·")
                                .foregroundColor(Palette.slateLight)
                                .font(.system(size: 11, weight: .bold))
                        }
                        thermalIndicator
                    }
                }
                .lineLimit(1)
                .animation(settings.hudMotion.animation, value: settings.hudShowStorageInfo)
                .animation(settings.hudMotion.animation, value: settings.hudShowBatteryInfo)
                .animation(settings.hudMotion.animation, value: settings.hudShowTimeRemaining)
            }

            if recorder.isRecording && settings.recordAudio {
                audioLevelBar
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .frame(minHeight: 36)
        .background(
            ZStack {
                // Single shared shape reused for both fills below so they can
                // never drift apart by even a fraction of a point at the corners.
                Palette.panel.opacity(0.84)
                // Flat fill on A10 — ultraThinMaterial is a live GPU blur.
                Palette.slateDeep.opacity(usesLightweightMaterial ? 0.55 : 0.25)
            }
        )
        // Clip to the ACTUAL rounded shape (not the bounding box) so the
        // material/fill never bleeds past the curve into a squared-off
        // sliver at the corners — this is what `.clipped()` was missing,
        // since it only clips to the rectangular frame.
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [
                            settings.accentColor.bright.opacity(0.5),
                            Color.white.opacity(0.1),
                            settings.accentColor.color.opacity(0.22)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        .shadow(color: .black.opacity(0.4), radius: 10, x: 0, y: 4)
    }

    var recordingStatusRow: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                if recorder.isRecording {
                    Facet(sides: 6)
                        .fill(Palette.record)
                        .frame(width: 10, height: 10)
                        .shadow(color: Palette.record, radius: blink ? 5 : 0)
                        .opacity(blink ? 0.3 : 1)
                        .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: blink)

                    Text("REC")
                        .font(.system(size: 12, weight: .black))
                        .fixedSize()
                    Text(Fmt.duration(recorder.elapsed))
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .fixedSize()

                    if let limit = settings.maxDuration.seconds {
                        Text("/ " + Fmt.duration(limit))
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(.white.opacity(0.55))
                            .fixedSize()
                    }

                    // Battery while filming — same indicator as idle HUD.
                    if settings.hudShowBatteryInfo {
                        Text("·")
                            .foregroundColor(Palette.slateLight)
                            .font(.system(size: 11, weight: .bold))
                            .fixedSize()
                        batteryIndicator
                    }

                    if recorder.droppedFrames > 0 {
                        Text("\(recorder.droppedFrames)d")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(settings.accentColor.bright)
                            .fixedSize()
                    }
                } else if recorder.isSaving {
                    ProgressView().tint(settings.accentColor.bright).scaleEffect(0.7)
                    Text("Saving…")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(settings.accentColor.bright)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.72)

            // 📊 Opt-in live stats (measured fps / bitrate) — Settings toggle,
            // off by default. Kept on its OWN row under REC/timer/battery
            // instead of tacked onto that line — cramming it in-line was
            // forcing the whole pill wider than its screen-edge cap, which
            // squeezed the flash/settings icons off to the side. A second
            // row grows the pill down instead of sideways, matching how the
            // idle-state pill already stacks its two info rows.
            if recorder.isRecording && (settings.showRecordingStats || showsTimeRemainingInPill) {
                HStack(spacing: 5) {
                    if settings.showRecordingStats {
                        HStack(spacing: 3) {
                            Image(systemName: "speedometer")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(Palette.slateLight)
                            Text(recorder.recordingStats.measuredFPSLabel)
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundColor(.white.opacity(0.68))
                        }
                        Text("·")
                            .foregroundColor(Palette.slateLight)
                            .font(.system(size: 11, weight: .bold))
                        HStack(spacing: 3) {
                            Image(systemName: "waveform")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(Palette.slateLight)
                            // Real on-disk bitrate is unavailable for the first
                            // few seconds of every clip (AVAssetWriter only
                            // flushes bytes at each movie-fragment boundary), so
                            // fall back to the configured target bitrate instead
                            // of showing a bare "--" the whole time.
                            Text(recorder.recordingStats.currentBitrateBps > 0
                                 ? recorder.recordingStats.currentBitrateLabel
                                 : RecordingStatsSnapshot.formatBitrate(Double(plan.videoBitrate)) + "*")
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundColor(.white.opacity(0.68))
                        }
                    }

                    // "~X h/min left" — was only ever built in the idle
                    // (non-recording) branch above, so it vanished the
                    // instant recording started even though the HUD toggle
                    // for it was on. Same formula, same look, just also
                    // rendered while recorder.isRecording is true.
                    if showsTimeRemainingInPill {
                        if settings.showRecordingStats {
                            Text("·")
                                .foregroundColor(Palette.slateLight)
                                .font(.system(size: 11, weight: .bold))
                        }
                        let hoursLeft = Double(max(0, recorder.freeBytes - 300_000_000)) / 1_000_000.0 / plan.megabytesPerHour
                        HStack(spacing: 3) {
                            Image(systemName: "clock")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(Palette.slateLight)
                            Text("~" + Fmt.hours(hoursLeft))
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundColor(.white.opacity(0.68))
                        }
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .foregroundColor(.white)
        .onAppear { blink = true }
        .onDisappear { blink = false }
    }

    var batteryIndicator: some View {
        let pct = recorder.batteryPercent
        let color: Color = recorder.batteryCharging ? settings.accentColor.bright
            : pct <= 20 ? Palette.record
            : pct <= 40 ? settings.accentColor.bright
            : .white.opacity(0.8)
        return HStack(spacing: 3) {
            Image(systemName: recorder.batteryCharging ? "battery.100.bolt" : "battery.75")
                .font(.system(size: 10))
            Text("\(pct)%")
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundColor(color)
    }

    var thermalIndicator: some View {
        let state = recorder.thermalState
        let color: Color = state == .critical ? Palette.record
            : state == .serious ? settings.accentColor.bright
            : .white.opacity(0.7)
        return HStack(spacing: 3) {
            Image(systemName: state.icon)
                .font(.system(size: 10))
            Text(state.shortLabel)
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundColor(color)
    }

    var audioLevelBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.15))
                Capsule()
                    .fill(LinearGradient(colors: [settings.accentColor.deep, audioLevelColor], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(3, geo.size.width * CGFloat(recorder.audioLevel)))
                    .animation(.spring(response: 0.2, dampingFraction: 0.8), value: recorder.audioLevel)
            }
        }
        .frame(width: 80, height: 4)
    }

    var audioLevelColor: Color {
        recorder.audioLevel > 0.85 ? Palette.record
            : recorder.audioLevel > 0.6 ? settings.accentColor.bright
            : settings.accentColor.color
    }

    // MARK: Pro Tools Menu
    //
    // The drawer body below only handles the header + card chrome. The
    // actual controls (Timer, Level meter, Exposure, White balance, ...)
    // are described as data in `proToolsDrawerControls` and rendered by
    // `ProToolsControlList` (see ProToolsControls.swift). To add a new
    // Pro Tools control, add one entry to `proToolsDrawerControls` — no
    // new hand-built VStack/HStack block needed.

    /// The list of controls shown in the Pro Tools ("Shoot") drawer, in
    /// display order. This is the single place to touch when adding,
    /// removing, or reordering a Pro Tools control.
    var proToolsDrawerControls: [ProToolControl] {
        let controls: [ProToolControl] = [
            .chips(ProToolControl.ChipsSpec(
                id: "timer",
                icon: "timer",
                title: "Timer",
                items: CountdownTimer.allCases.map { timer in
                    ProToolControl.ChipsSpec.Item(
                        id: timer.label,
                        label: timer.label,
                        selected: settings.countdownTimer == timer,
                        action: { settings.countdownTimer = timer }
                    )
                }
            )),
            .toggle(ProToolControl.ToggleSpec(
                id: "levelMeter",
                icon: "gyroscope",
                title: "Level meter",
                isOn: $settings.showLevelGauge,
                onChange: { _ in recorder.refreshMotionUpdateRate() }
            )),
            .slider(ProToolControl.SliderSpec(
                id: "exposure",
                icon: "plusminus.circle.fill",
                title: "Exposure",
                value: $settings.exposureBias,
                range: -2.0...2.0,
                step: 0.1,
                valueLabel: { String(format: "%@%.1f EV", $0 > 0 ? "+" : "", $0) },
                onChange: { recorder.setExposureBias($0) },
                defaultValue: 0
            )),
            .navigation(ProToolControl.NavigationSpec(
                id: "whiteBalance",
                icon: settings.whiteBalance.icon,
                title: "White balance",
                valueLabel: settings.whiteBalance.label,
                action: {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                        showWhiteBalanceSheet = true
                    }
                }
            ))
        ]
        return controls
    }

    var proToolsDrawer: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(settings.accentColor.color)
                    Text("Pro Tools")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                }
                Spacer()
                Button(action: {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) { showProMenu = false }
                }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white.opacity(0.7))
                        .frame(width: 22, height: 22)
                        .background(Palette.slateMid)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 2)

            // No ScrollView: with the zoom-presets row gone, the remaining
            // controls (Timer, Level meter, Exposure, White balance) fit
            // without scrolling even on iPhone 7's 667pt-tall screen, and
            // the drawer's own compact row spacing (see ProToolsControls.swift)
            // keeps it that way as a hard requirement, not just today's fit.
            ProToolsControlList(
                controls: proToolsDrawerControls,
                accentColor: settings.accentColor.color,
                hapticsEnabled: settings.hapticFeedbackEnabled
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Palette.slateDeep.opacity(0.97))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .compositingGroup()
        .shadow(color: .black.opacity(0.4), radius: 10, x: 0, y: 4)
        .sheet(isPresented: $showWhiteBalanceSheet) {
            whiteBalanceSheet
        }
    }

    // MARK: White Balance sheet
    //
    // Same "icon badge + title + subtitle + chevron" list pattern as Quick
    // Presets in SettingsScreen.swift, so picking a white balance preset
    // feels like the rest of the app instead of a one-off row of chips.
    var whiteBalanceSheet: some View {
        NavigationView {
            List {
                ForEach(WhiteBalancePreset.allCases) { preset in
                    Button(action: {
                        settings.whiteBalance = preset
                        recorder.setWhiteBalance(preset)
                        showWhiteBalanceSheet = false
                    }) {
                        HStack(spacing: 12) {
                            Image(systemName: preset.icon)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(width: 30, height: 30)
                                .background(
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .fill(settings.accentColor.color)
                                )
                            VStack(alignment: .leading, spacing: 2) {
                                Text(preset.label)
                                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                                    .foregroundColor(.primary)
                                Text(preset.detail)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            if settings.whiteBalance == preset {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundColor(settings.accentColor.color)
                            }
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("White Balance")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Cancel") { showWhiteBalanceSheet = false }
                }
            }
        }
        .tint(settings.accentColor.color)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    // MARK: Bottom HUD Bar (Live Zoom Always Visible)

}
