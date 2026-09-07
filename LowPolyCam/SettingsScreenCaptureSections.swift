import SwiftUI

extension SettingsScreen {

    var summarySection: some View {
        Section {
            HStack(spacing: 11) {
                Image(systemName: settings.cameraMode == .photo ? "camera.fill" : "video.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 32, height: 32)
                    .background(settings.accentColor.color, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(settings.cameraMode.label) · \(compactPlanLabel)")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                    if settings.cameraMode != .photo {
                        Text("\(shortQualityLabel(settings.quality)) · \(settings.saveLocation.label) · ~\(Int(plan.megabytesPerHour.rounded())) MB/h")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    } else {
                        Text(settings.saveLocation.label)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundColor(.secondary)
                    }
                }
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(Fmt.size(freeBytesSnapshot))
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundColor(settings.accentColor.color)
                    Text("free")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.vertical, 1)
        }
    }

    var compactPlanLabel: String {
        if settings.cameraMode == .photo {
            return settings.photoMegapixels.label
        }
        if settings.cameraMode == .slowMo {
            return "\(settings.slowMoResolution.label) · \(settings.slowMoFrameRate.label)"
        }
        return "\(settings.resolution.label) · \(settings.frameRate.label)"
    }

    // MARK: - Video capture (res + fps + quality in one place)

    var videoCaptureSection: some View {
        Section(header: sectionHeader("Video", icon: "video.fill"),
                footer: Text("Swipe chips sideways for more options (e.g. 144p).")) {
            labeledChipRow(title: "Resolution", showMoreHint: true) {
                // Front camera: hide unsupported entirely. Rear: show grey/locked.
                let resItems: [Resolution] = isFrontSnapshot
                    ? availableResolutions
                    : Resolution.allCases.filter { $0 != .p144 || availableResolutions.contains(.p144) }
                chipRow(resItems.map { r in
                    ChipItem(id: r.id, label: r.label,
                             enabled: availableResolutions.contains(r),
                             selected: settings.resolution == r) {
                        settings.resolution = r
                        if let locked = r.lockedFrameRate {
                            settings.frameRate = locked
                        }
                        recorder.updateCaptureFormat()
                    }
                })
            }

            labeledChipRow(title: "Frame rate") {
                let rateItems: [FrameRate] = isFrontSnapshot ? availableFrameRates : FrameRate.allCases
                chipRow(rateItems.map { f in
                    let enabled = availableFrameRates.contains(f)
                    return ChipItem(id: "fr-\(f.id)", label: f.label,
                                     enabled: enabled,
                                     selected: settings.frameRate == f) {
                        settings.frameRate = f
                        recorder.updateCaptureFormat()
                    }
                })
            }

            labeledChipRow(title: "Quality") {
                chipRow(Quality.allCases.map { q in
                    ChipItem(id: q.id, label: shortQualityLabel(q),
                              selected: settings.quality == q) {
                        settings.quality = q
                    }
                })
            }
        }
    }

    func labeledChipRow<Content: View>(title: String, showMoreHint: Bool = false, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundColor(.primary)
                if showMoreHint {
                    Image(systemName: "chevron.left.2")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.secondary)
                    Text("swipe")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundColor(.secondary)
                }
            }
            content()
        }
        .padding(.vertical, 2)
    }

    // MARK: - Output

    var outputSection: some View {
        Section(header: sectionHeader("Output", icon: "tray.and.arrow.down.fill"),
                footer: Text(settings.cameraMode == .photo
                             ? settings.saveLocation.detail
                             : "Where clips go, and how long each file runs.")) {
            // Save destination as clear tappable choices
            HStack(spacing: 10) {
                ForEach(SaveLocation.allCases) { loc in
                    let on = settings.saveLocation == loc
                    Button {
                        settings.saveLocation = loc
                        if settings.hapticFeedbackEnabled { presetHaptic.selectionChanged() }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: loc == .photos ? "photo.on.rectangle" : "folder.fill")
                                .font(.system(size: 12, weight: .semibold))
                            Text(loc.label)
                                .font(.system(size: 14, weight: .semibold, design: .rounded))
                        }
                        .foregroundColor(on ? .white : .primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(on ? settings.accentColor.color : Color.secondary.opacity(0.14))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 8, trailing: 16))

            if settings.cameraMode != .photo {
                HStack(spacing: 8) {
                    Text("Split")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundColor(.primary)
                        .frame(width: 44, alignment: .leading)
                    ForEach(SplitInterval.allCases) { interval in
                        let on = settings.splitInterval == interval
                        Button {
                            settings.splitInterval = interval
                            if settings.hapticFeedbackEnabled { presetHaptic.selectionChanged() }
                        } label: {
                            Text(shortSplitLabel(interval))
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .foregroundColor(on ? .white : .primary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(
                                    Capsule().fill(on ? settings.accentColor.color : Color.secondary.opacity(0.14))
                                )
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer(minLength: 0)
                }

                Picker(selection: $settings.maxDuration) {
                    ForEach(MaxDuration.allCases) { d in
                        Text(d.label).tag(d)
                    }
                } label: {
                    Label("Auto-stop", systemImage: "timer")
                        .labelStyle(SettingsLabelStyle(color: settings.accentColor.color))
                }

                infoRow("Space / hour", "\(Int(plan.megabytesPerHour.rounded())) MB")
                infoRow("Room left", Fmt.hours(hoursLeft))
            }
        }
    }

    // MARK: - Banner

    var frontCameraBanner: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: "person.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 30, height: 30)
                    .background(settings.accentColor.color)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text("Selfie camera")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                    Text("Only options this lens supports are shown.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: - Capture

    var resolutionSection: some View {
        Section(header: sectionHeader("Resolution", icon: "rectangle.dashed"),
                footer: Text("Recording at \(plan.sizeLabel).")) {
            let resItems: [Resolution] = isFrontSnapshot
                ? availableResolutions
                : Resolution.allCases.filter { $0 != .p144 || availableResolutions.contains(.p144) }
            chipRow(resItems.map { r in
                ChipItem(id: r.id, label: r.label,
                         enabled: availableResolutions.contains(r),
                         selected: settings.resolution == r) {
                    settings.resolution = r
                    if let locked = r.lockedFrameRate {
                        settings.frameRate = locked
                    }
                    recorder.updateCaptureFormat()
                }
            })
        }
    }

    var frameRateSection: some View {
        Section(header: sectionHeader("Frame Rate", icon: "timer"),
                footer: Text("Only frame rates supported by the active camera are selectable.")) {
            let rateItems: [FrameRate] = isFrontSnapshot ? availableFrameRates : FrameRate.allCases
            chipRow(rateItems.map { f in
                let enabled = availableFrameRates.contains(f)
                return ChipItem(id: "fr-\(f.id)", label: f.label,
                                 enabled: enabled,
                                 selected: settings.frameRate == f) {
                    settings.frameRate = f
                    recorder.updateCaptureFormat()
                }
            })
        }
    }

    /// Video / Slow-Mo bitrate quality only (not used for still photos).
    var videoQualitySection: some View {
        Section(header: sectionHeader("Quality", icon: "slider.horizontal.3"),
                footer: Text(videoQualityFooter)) {
            chipRow(Quality.allCases.map { q in
                ChipItem(id: q.id, label: shortQualityLabel(q),
                          selected: settings.quality == q) {
                    settings.quality = q
                }
            })
        }
    }

    var videoQualityFooter: String {
        switch settings.quality {
        case .high: return "Highest bitrate · larger files"
        case .medium: return "Balanced quality and size"
        case .low: return "Smaller files · still clear"
        case .ultraLow: return "Smallest files · longest sessions"
        }
    }

    func shortQualityLabel(_ q: Quality) -> String {
        switch q {
        case .high: return "High"
        case .medium: return "Medium"
        case .low: return "Low"
        case .ultraLow: return "Data Saver"
        }
    }

    // MARK: - Quick Presets (entry + sheet)

    var quickPresetsEntrySection: some View {
        Section {
            Button(action: { showPresetsSheet = true }) {
                HStack(spacing: 12) {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 28, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(settings.accentColor.color)
                        )
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Quick Presets")
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                            .foregroundColor(.primary)
                        Text("Balanced, Social, All Day…")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.secondary.opacity(0.5))
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    var presetsSheet: some View {
        NavigationView {
            List {
                ForEach(CapturePreset.all.filter { preset in
                    // Front camera: no 4K, and no 60 fps if the lens can't do it.
                    if recorder.isFrontCamera {
                        if preset.resolution == .p2160 { return false }
                        if preset.frameRate == .fps60 && !recorder.availableFrameRates.contains(.fps60) {
                            return false
                        }
                    }
                    return true
                }) { preset in
                    Button(action: {
                        applyPresetNow(preset)
                        showPresetsSheet = false
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
                                Text(preset.name)
                                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                                    .foregroundColor(.primary)
                                Text(preset.detail)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.secondary.opacity(0.45))
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Quick Presets")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Cancel") { showPresetsSheet = false }
                }
            }
        }
        .tint(settings.accentColor.color)
    }

    func applyPresetNow(_ preset: CapturePreset) {
        presetHaptic.selectionChanged()
        presetHaptic.prepare()
        appliedPresetId = preset.id
        settings.applyPreset(preset)
        recorder.updateCaptureFormat()
        recorder.syncMicInput()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            if appliedPresetId == preset.id { appliedPresetId = nil }
        }
    }

    // MARK: - Save / Split / Duration

    var saveSection: some View {
        Section(header: sectionHeader("Save To", icon: "folder.fill"),
                footer: Text(settings.saveLocation.detail)) {
            chipRow(SaveLocation.allCases.map { s in
                ChipItem(id: s.id, label: s.label, selected: settings.saveLocation == s) {
                    settings.saveLocation = s
                }
            })
        }
    }

    var splitSection: some View {
        Section(header: sectionHeader("Split Recordings", icon: "scissors"),
                footer: Text("Shorter segments are easier to transfer and edit. No frames are lost.")) {
            chipRow(SplitInterval.allCases.map { interval in
                ChipItem(id: interval.id, label: shortSplitLabel(interval),
                          selected: settings.splitInterval == interval) {
                    settings.splitInterval = interval
                }
            })
        }
    }

    func shortSplitLabel(_ interval: SplitInterval) -> String {
        switch interval {
        case .off: return "Off"
        case .oneHour: return "1 hr"
        case .fourHours: return "4 hr"
        }
    }

    var maxDurationSection: some View {
        Section(header: sectionHeader("Auto-Stop", icon: "timer"),
                footer: Text("Stops recording when the timer hits the limit.")) {
            Picker(selection: $settings.maxDuration) {
                ForEach(MaxDuration.allCases) { d in
                    Text(d.label).tag(d)
                }
            } label: {
                Label("Max duration", systemImage: "timer")
                    .labelStyle(SettingsLabelStyle(color: settings.accentColor.color))
            }
            if settings.maxDuration != .off {
                Text(settings.maxDuration.subtitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Estimates (uses snapshot — no live updates)

    var estimateSection: some View {
        Section(header: sectionHeader("Storage Cost", icon: "internaldrive")) {
            infoRow("Space per hour", "\(Int(plan.megabytesPerHour.rounded())) MB")
            infoRow("Room left", Fmt.hours(hoursLeft))
            infoRow("Bitrate", "\(plan.videoBitrate / 1000) kbit/s"
                     + (plan.hasAudio ? " + \(plan.audioBitrate / 1000) audio" : ""))
            infoRow("Free space", Fmt.size(freeBytesSnapshot))
        }
    }

    // MARK: - Assist (mode-specific)
    //
    // Each mode's Capture Assist section picks a subset of `assistToggles`
    // (declared below) plus the `assistGrid` picker. To add a new Assist
    // toggle: add one `SettingsToggleSpec` to `assistToggles`, then list its
    // `id` in whichever mode section(s) should show it — no new `some View`
    // property required. See SettingsRowKit.swift for how the group renders.

    /// Every Capture Assist toggle, keyed by id. Mode sections below select
    /// a subset by id via `assistToggleGroup(ids:)`.
    var assistToggles: [SettingsToggleSpec] {
        [
            SettingsToggleSpec(
                id: "stabilisation",
                title: "Stabilisation",
                icon: "hand.raised.fill",
                isOn: $settings.stabilization,
                onChange: { _ in recorder.updateStabilization() },
                // Hide (not grey) when this lens cannot stabilise (typical for front camera).
                isVisible: stabilizationSupported
            ),
            SettingsToggleSpec(
                id: "levelMeter",
                title: "Level meter",
                icon: "gyroscope",
                isOn: $settings.showLevelGauge
            ),
            SettingsToggleSpec(
                id: "autoDim",
                title: "Auto-dim when filming",
                icon: "moon.stars.fill",
                isOn: $settings.autoDimOnRecord
            ),
            SettingsToggleSpec(
                id: "longevity",
                title: "Longevity Mode",
                icon: "leaf.fill",
                isOn: $settings.longevityMode,
                onChange: { _ in recorder.refreshIdleFormatIfNeeded() }
            ),
            // 📊 Opt-in live stats readout (measured fps / bitrate) shown in
            // the recording HUD. Off by default — purely additive.
            SettingsToggleSpec(
                id: "recordingStats",
                title: "Live recording stats",
                icon: "waveform.path.ecg",
                isOn: $settings.showRecordingStats
            ),
            // Reopens on whichever camera (front/rear) was active last,
            // instead of always resetting to the rear camera on launch.
            SettingsToggleSpec(
                id: "keepLastCamera",
                title: "Keep last camera",
                icon: "arrow.triangle.2.circlepath.camera",
                isOn: $settings.keepLastCamera
            )
        ]
    }

    /// Renders the subset of `assistToggles` matching `ids`, in `ids` order.
    func assistToggleGroup(ids: [String]) -> some View {
        let bySpecId = Dictionary(uniqueKeysWithValues: assistToggles.map { ($0.id, $0) })
        let ordered = ids.compactMap { bySpecId[$0] }
        return SettingsToggleGroup(specs: ordered, accentColor: settings.accentColor.color, settings: settings)
    }

    var videoAssistSection: some View {
        Section(header: sectionHeader("Capture Assist", icon: "viewfinder")) {
            assistToggleGroup(ids: ["stabilisation"])
            assistGrid
            assistToggleGroup(ids: ["levelMeter", "autoDim", "longevity", "recordingStats", "keepLastCamera"])
            volumeButtonPicker
        }
    }

    var slowMoAssistSection: some View {
        Section(header: sectionHeader("Capture Assist", icon: "viewfinder"),
                footer: Text("Video-only options (split, HEVC presets) are hidden in Slow-Mo.")) {
            assistGrid
            assistToggleGroup(ids: ["levelMeter", "longevity", "recordingStats", "keepLastCamera"])
            volumeButtonPicker
        }
    }

    var photoAssistSection: some View {
        Section(header: sectionHeader("Capture Assist", icon: "viewfinder"),
                footer: Text("Video settings are hidden while you are in Photo mode.")) {
            assistGrid
            assistToggleGroup(ids: ["levelMeter", "keepLastCamera"])
            volumeButtonPicker
        }
    }

    /// Volume-button behavior picker — lives at the tail of Capture Assist
    /// in every mode (same section, same spot) rather than a dedicated
    /// top-level section, since it's a small one-row preference.
    var volumeButtonPicker: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsPickerRow(
                title: "Volume button",
                icon: "volume.2.fill",
                accentColor: settings.accentColor.color,
                selection: $settings.volumeButtonAction,
                label: { (v: VolumeButtonAction) -> Text in Text(v.label) }
            )
            pickerDetailCaption(settings.volumeButtonAction.detail)
        }
    }

    var assistGrid: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsPickerRow(
                title: "Grid overlay",
                icon: "grid",
                accentColor: settings.accentColor.color,
                selection: $settings.gridStyle,
                label: { (v: GridStyle) -> Text in Text(v.label) }
            )
            pickerDetailCaption(settings.gridStyle.detail)
        }
    }

    /// Small secondary line under a picker row showing what the currently
    /// selected value actually does — used under HUD animation and Grid
    /// overlay so the picker's effect isn't just a bare name.
    func pickerDetailCaption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(.secondary)
            .padding(.leading, 40) // aligns under the picker's label text, past its icon
            .padding(.top, 2)
    }

    // MARK: - Output (mode-specific)

    var slowMoOutputSection: some View {
        Section(header: sectionHeader("Output", icon: "tray.and.arrow.down.fill")) {
            outputSaveButtons
            infoRow("Space / hour", "\(Int(plan.megabytesPerHour.rounded())) MB")
            infoRow("Room left", Fmt.hours(hoursLeft))
        }
    }

    var photoOutputSection: some View {
        Section(header: sectionHeader("Output", icon: "tray.and.arrow.down.fill"),
                footer: Text(settings.saveLocation.detail)) {
            outputSaveButtons
        }
    }

    var outputSaveButtons: some View {
        HStack(spacing: 10) {
            ForEach(SaveLocation.allCases) { loc in
                let on = settings.saveLocation == loc
                Button {
                    settings.saveLocation = loc
                    if settings.hapticFeedbackEnabled { presetHaptic.selectionChanged() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: loc == .photos ? "photo.on.rectangle" : "folder.fill")
                            .font(.system(size: 12, weight: .semibold))
                        Text(loc.label)
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                    }
                    .foregroundColor(on ? .white : .primary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(on ? settings.accentColor.color : Color.secondary.opacity(0.14))
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 8, trailing: 16))
    }

    // MARK: - Camera HUD (entry + sheet, same pattern as Quick Presets)

    /// `HUDElement`s that live in the Info Pill group instead of the general
    /// Camera HUD group — the pill itself, plus the readouts that actually
    /// render inside it (battery / storage & time left), rather than being
    /// separate viewfinder chrome.
}
