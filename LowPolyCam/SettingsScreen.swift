//
//  SettingsScreen.swift
//  LowPolyCam
//
//  Updated for iOS 27 / Xcode 27 / Swift 6.4.
//  Swift 6 complete concurrency · Observation · Liquid Glass · RotationCoordinator
//

import SwiftUI

// MARK: - Lightweight label style (keeps List scrolling smooth on A10)

struct SettingsLabelStyle: LabelStyle {
    var color: Color
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 12) {
            configuration.icon
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        // Always the selected theme accent — never deep/bright variants.
                        .fill(color)
                )
            configuration.title
                .font(.system(size: 16, weight: .medium, design: .rounded))
        }
    }
}

struct SettingsScreen: View {

    @ObservedObject var settings: AppSettings
    /// Recorder is only used for one-shot capability checks + format updates.
    /// We intentionally do NOT observe live battery/free-space ticks while the
    /// sheet is open — that was the main source of scroll stutter in photo / slo-mo.
    @ObservedObject var recorder: CameraRecorder
    @Environment(\.dismiss) var dismiss

    @State var appliedPresetId: String? = nil
    @State var showPresetsSheet = false
    @State var showHUDSheet = false
    @State var showAboutSheet = false
    @State var showCustomColorSheet = false
    @State var presetHaptic = UISelectionFeedbackGenerator()
    @State var freeBytesSnapshot: Int64 = 0
    @State var isFrontSnapshot = false
    @State var availableResolutions: [Resolution] = Resolution.allCases
    @State var availableFrameRates: [FrameRate] = FrameRate.allCases
    /// Full per-resolution fps capability (see `CameraRecorder.frameRatesByResolution`).
    /// Lets the frame-rate row re-scope instantly on `settings.resolution`
    /// changes instead of only refreshing next time Settings is reopened.
    @State var frameRatesByResolution: [Resolution: Set<FrameRate>] = [:]
    @State var availableSlowMoRates: [SlowMoFrameRate] = SlowMoFrameRate.allCases
    @State var availableSlowMoResolutions: [Resolution] = [.p1080, .p720]
    @State var availablePhotoMegapixels: [PhotoMegapixels] = PhotoMegapixels.allCases
    @State var isSlowMoSupported = true
    @State var stabilizationSupported = true

    var plan: EncodePlan { Encoder.plan(for: settings) }

    var body: some View {
        NavigationView {
            List {
                summarySection

                if isFrontSnapshot { frontCameraBanner }

                // Strict mode separation — nothing that does not affect the active mode.
                switch settings.cameraMode {
                case .video:
                    quickPresetsEntrySection
                    videoCaptureSection
                    outputSection
                    // Same in every mode — the live HUD chrome isn't mode-specific.
                    // Sits between Output and Capture Assist in every mode.
                    hudEntrySection
                    videoAssistSection
                    advancedSection
                case .slowMo:
                    slowMoFrameRateSection
                    slowMoResolutionSection
                    videoQualitySection
                    outputSection
                    hudEntrySection
                    slowMoAssistSection
                    advancedSection
                case .photo:
                    // Photo only: size + where to save + framing assists.
                    // No video quality, codec, frame rate, stab, split, etc.
                    photoMegapixelsSection
                    photoBurstSection
                    photoFormatSection
                    photoOutputSection
                    hudEntrySection
                    photoAssistSection
                }

                if settings.cameraMode != .photo {
                    Section("Audio") {
                        Toggle("Record sound", isOn: $settings.recordAudio)
                            .onChange(of: settings.recordAudio) { _, _ in recorder.syncMicInput() }
                    }
                }
                Section("Capture behavior") {
                    Toggle("Save selfies unmirrored", isOn: $settings.saveSelfiesUnmirrored)
                    Toggle("Capture flash confirmation", isOn: $settings.captureFlashConfirmation)
                }
                feedbackSection
                appearanceSection

                // Small entry — opens Good to Know sheet
                aboutEntrySection
            }
            .listStyle(.insetGrouped)
            .id(settings.cameraMode)
            .animation(nil, value: settings.cameraMode)
            .animation(nil, value: settings.accentColor)
            .animation(nil, value: appliedPresetId)
            .transaction { $0.animation = nil }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { dismiss() }) {
                        Text("Done")
                            .font(.system(size: 16, weight: .bold))
                    }
                }
            }
            .sheet(isPresented: $showPresetsSheet) {
                presetsSheet
            }
            .sheet(isPresented: $showHUDSheet) {
                hudSheet
            }
            .sheet(isPresented: $showAboutSheet) {
                aboutSheet
            }
            .sheet(isPresented: $showCustomColorSheet) {
                customColorSheet
            }
        }
        .tint(settings.accentColor.color)
        .onAppear {
            syncCapabilitiesFromRecorder()
        }
        .onReceive(recorder.$frameRatesByResolution) { _ in
            DispatchQueue.main.async { syncCapabilitiesFromRecorder() }
        }
        .onReceive(recorder.$slowRatesByResolution) { _ in
            DispatchQueue.main.async { syncCapabilitiesFromRecorder() }
        }
        .onReceive(recorder.$freeBytes) { freeBytesSnapshot = $0 }
        .onChange(of: settings.slowMoResolution) { _, newRes in
            // Instantly re-scope FPS chips to the newly selected slow-mo resolution
            // without waiting for the async format-apply round-trip.
            let rates = recorder.slowRatesByResolution[newRes] ?? []
            availableSlowMoRates = SlowMoFrameRate.allCases.filter { rates.contains($0) }
            if !availableSlowMoRates.contains(settings.slowMoFrameRate) {
                settings.slowMoFrameRate = availableSlowMoRates.first ?? .fps120
            }
            recorder.updateCaptureFormat()
        }
        .onChange(of: settings.resolution) { _, newRes in
            // Same fix as slow-mo above: re-scope the video fps chips to the
            // newly selected resolution right away, from the already-known
            // per-resolution map — instead of leaving the previous
            // resolution's fps list (e.g. 4K's 30-fps-only scan) applied
            // until Settings is closed and reopened.
            let rates = frameRatesByResolution[newRes] ?? Set(FrameRate.allCases)
            availableFrameRates = FrameRate.allCases.filter { rates.contains($0) }
            if !availableFrameRates.contains(settings.frameRate) {
                settings.frameRate = availableFrameRates.contains(.fps30)
                    ? .fps30 : (availableFrameRates.first ?? .fps30)
            }
        }
    }

    func syncCapabilitiesFromRecorder() {
        presetHaptic.prepare()
        freeBytesSnapshot = recorder.freeBytes
        isFrontSnapshot = recorder.isFrontCamera
        availableResolutions = recorder.availableResolutions
        frameRatesByResolution = recorder.frameRatesByResolution
        // Scope to the resolution that's actually selected right now, from the
        // full per-resolution map — not whatever `recorder.availableFrameRates`
        // last happened to be scoped to.
        if let rates = frameRatesByResolution[settings.resolution] {
            availableFrameRates = FrameRate.allCases.filter { rates.contains($0) }
        } else {
            availableFrameRates = recorder.availableFrameRates
        }
        availableSlowMoRates = recorder.availableSlowMoRates
        availableSlowMoResolutions = recorder.availableSlowMoResolutions
        availablePhotoMegapixels = recorder.availablePhotoMegapixels
        isSlowMoSupported = recorder.isSlowMoSupportedOnCurrentLens
        stabilizationSupported = recorder.stabilizationSupported
    }

    // MARK: - Summary card

    var hoursLeft: Double {
        let perHour = plan.megabytesPerHour * 1_000_000
        guard perHour > 0 else { return 0 }
        return Double(max(0, freeBytesSnapshot - CameraRecorder.reserveBytes)) / perHour
    }
}

// MARK: - Snappy preset button

struct PresetButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.65 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
