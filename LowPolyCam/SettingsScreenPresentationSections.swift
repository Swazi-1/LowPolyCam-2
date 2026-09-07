import SwiftUI

extension SettingsScreen {

    var pillElementIds: Set<HUDElement> { [.infoPill, .batteryInfo, .storageInfo, .megapixels, .timeRemaining] }

    /// One `SettingsToggleSpec` per `HUDElement`, built generically from
    /// `AppSettings.binding(for:)` so adding a new hideable element later
    /// is a one-line change in `HUDElement` + `AppSettings`, not here.
    /// Excludes the info-pill group (see `pillToggles`) so the sheet can
    /// group "chrome around the viewfinder" separately from "what's in
    /// the pill".
    var hudToggles: [SettingsToggleSpec] {
        HUDElement.allCases.filter { !pillElementIds.contains($0) }.map { element in
            SettingsToggleSpec(
                id: element.id,
                title: element.title,
                icon: element.icon,
                isOn: settings.binding(for: element)
            )
        }
    }

    /// Info-pill-specific toggles: the pill's own visibility plus the two
    /// readouts it actually displays (battery, storage & time left) — kept
    /// together since hiding those only makes sense in the context of the
    /// pill they live in.
    var pillToggles: [SettingsToggleSpec] {
        HUDElement.allCases.filter { pillElementIds.contains($0) }.map { element in
            SettingsToggleSpec(
                id: element.id,
                title: element.title,
                icon: element.icon,
                isOn: settings.binding(for: element)
            )
        }
    }

    var hudEntrySection: some View {
        Section {
            Button(action: { showHUDSheet = true }) {
                HStack(spacing: 12) {
                    Image(systemName: "camera.viewfinder")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 28, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(settings.accentColor.color)
                        )
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Camera HUD")
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                            .foregroundColor(.primary)
                        Text("Overlay elements, info pill, animation")
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

    var hudSheet: some View {
        NavigationView {
            List {
                Section(header: sectionHeader("Camera HUD", icon: "camera.viewfinder"),
                        footer: Text("Hide anything you don't want cluttering the viewfinder. The shutter and this Settings button always stay visible.")) {
                    SettingsToggleGroup(specs: hudToggles, accentColor: settings.accentColor.color, settings: settings)
                }

                Section(header: sectionHeader("Info Pill", icon: "capsule.fill"),
                        footer: Text("The compact format readout shown while filming.")) {
                    SettingsToggleGroup(specs: pillToggles, accentColor: settings.accentColor.color, settings: settings)
                }

                Section(header: sectionHeader("Animation", icon: "wand.and.stars")) {
                    VStack(alignment: .leading, spacing: 0) {
                        SettingsPickerRow(
                            title: "HUD animation",
                            icon: "wand.and.stars",
                            accentColor: settings.accentColor.color,
                            selection: $settings.hudMotion,
                            label: { (v: HUDMotion) -> Text in Text(v.label) }
                        )
                        pickerDetailCaption(settings.hudMotion.detail)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Camera HUD")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { showHUDSheet = false }
                }
            }
        }
        .tint(settings.accentColor.color)
    }

    // MARK: - Feedback (sounds / haptics)

    var feedbackSection: some View {
        Section(header: sectionHeader("Sounds & Haptics", icon: "speaker.wave.2.fill"),
                footer: Group {
                    if settings.hapticFeedbackEnabled {
                        Text("Intensity applies to shutter, record start/stop, and countdown taps.")
                    }
                }) {
            Toggle(isOn: $settings.shutterSoundEnabled) {
                Label("Shutter & dial sounds", systemImage: "speaker.wave.2.fill")
                    .labelStyle(SettingsLabelStyle(color: settings.accentColor.color))
            }
            .onChange(of: settings.shutterSoundEnabled) { _, _ in
                fireSettingsToggleHaptic(settings)
            }

            Toggle(isOn: $settings.hapticFeedbackEnabled) {
                Label("Haptic feedback", systemImage: "hand.tap.fill")
                    .labelStyle(SettingsLabelStyle(color: settings.accentColor.color))
            }
            .onChange(of: settings.hapticFeedbackEnabled) { _, isOn in
                // Only buzz on the way to "on" — buzzing after switching it
                // off would be confusing (and pointless).
                guard isOn else { return }
                fireSettingsToggleHaptic(settings)
            }

            if settings.hapticFeedbackEnabled {
                hapticStrengthRow
            }
        }
    }

    var hapticStrengthRow: some View {
        SettingsPickerRow(title: "Haptic Strength", icon: "waveform.path",
                          accentColor: settings.accentColor.color,
                          selection: $settings.hapticIntensity,
                          label: { Text($0.label) })
    }

    // MARK: - Good to Know entry + sheet

    var aboutEntrySection: some View {
        Section {
            Button(action: { showAboutSheet = true }) {
                HStack {
                    Image(systemName: "info.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(settings.accentColor.color)
                    Text("Good to Know")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundColor(.primary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.secondary.opacity(0.5))
                }
                .padding(.vertical, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    var aboutSheet: some View {
        NavigationView {
            List {
                aboutRow(icon: "shield.lefthalf.filled",
                         title: "Crash Safe",
                         body: "Clips save in small pieces so a dead battery rarely loses the whole take.")
                aboutRow(icon: "moon.fill",
                         title: "Cooler When Idle",
                         body: "Preview uses a lighter sensor path until you hit record.")
                aboutRow(icon: "leaf.fill",
                         title: "Longevity Mode",
                         body: "Optional. Lower heat and smaller files for long sessions on older iPhones.")
                aboutRow(icon: "sparkles",
                         title: "v4 Beta 3",
                         body: "Built for iPhone 11+ with the iOS 26/27 AVFoundation camera stack.")
                aboutRow(icon: "volume.2.fill",
                         title: "Volume Buttons",
                         body: "Set what they do — shutter (photo tap / video toggle), always Burst, or always Record — under Capture Assist for each mode.")
                aboutRow(icon: "hand.tap.fill",
                         title: "Haptic Strength",
                         body: "Tap Light / Standard / Strong under Sounds & Haptics to feel each one before picking.")
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Good to Know")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { showAboutSheet = false }
                }
            }
        }
        .tint(settings.accentColor.color)
    }

    // MARK: - Appearance

    var appearanceSection: some View {
        Section(header: sectionHeader("Theme", icon: "paintpalette.fill"),
                footer: Text("Accent for shutter, highlights and controls.")) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(AccentColor.allCases) { color in
                        let isSelected = settings.accentColor == color
                        Button(action: {
                            settings.accentColor = color
                            presetHaptic.selectionChanged()
                            // Custom swatch: opens the color picker on every tap, whether
                            // this is the first pick or a re-tap to adjust the hue.
                            if color == .custom {
                                showCustomColorSheet = true
                            }
                        }) {
                            VStack(spacing: 6) {
                                Group {
                                    if color == .custom {
                                        ZStack {
                                            Circle()
                                                .fill(
                                                    LinearGradient(
                                                        colors: [color.bright, color.color],
                                                        startPoint: .topLeading,
                                                        endPoint: .bottomTrailing
                                                    )
                                                )
                                            Image(systemName: "eyedropper.halffull")
                                                .font(.system(size: 12, weight: .bold))
                                                .foregroundColor(.white)
                                        }
                                    } else {
                                        Circle()
                                            .fill(
                                                LinearGradient(
                                                    colors: [color.bright, color.color],
                                                    startPoint: .topLeading,
                                                    endPoint: .bottomTrailing
                                                )
                                            )
                                    }
                                }
                                .frame(width: 36, height: 36)
                                .overlay(
                                    Circle()
                                        .stroke(Color.white, lineWidth: isSelected ? 2.5 : 0)
                                )
                                .shadow(color: color.color.opacity(isSelected ? 0.45 : 0.12),
                                        radius: isSelected ? 6 : 2)
                                Text(shortAccentName(color))
                                    .font(.system(size: 11, weight: isSelected ? .bold : .medium, design: .rounded))
                                    .foregroundColor(isSelected ? color.bright : .secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(color.label)
                    }
                }
                .padding(.vertical, 6)
            }
        }
    }

    func shortAccentName(_ color: AccentColor) -> String {
        switch color {
        case .violet: return "Lavender"
        case .amber: return "Gold"
        case .red: return "Red"
        case .ice: return "Ice"
        case .aurora: return "Aurora"
        case .coral: return "Coral"
        case .custom: return "Custom"
        }
    }

    var customColorSheet: some View {
        NavigationView {
            List {
                Section(footer: Text("Pick any color for the shutter ring, highlights, and controls throughout the camera UI.")) {
                    ColorPicker(selection: Binding(
                        get: { settings.customColor },
                        set: { newColor in
                            settings.customAccentColorHex = newColor.toHexString()
                            settings.accentColor = .custom
                        }
                    ), supportsOpacity: false) {
                        Label("Custom accent color", systemImage: "eyedropper.halffull")
                            .labelStyle(SettingsLabelStyle(color: settings.customColor))
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Custom Color")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { showCustomColorSheet = false }
                }
            }
        }
        .tint(settings.customColor)
    }

    // MARK: - Advanced

    var advancedSection: some View {
        Section(header: sectionHeader("Video Format", icon: "film"),
                footer: Text(settings.useHEVC
                             ? "HEVC packs the same picture into roughly half the space."
                             : "H.264 plays everywhere but needs more space.")) {

            row(title: "HEVC",
                subtitle: "Smaller files · modern default",
                icon: "sparkles",
                iconColor: settings.accentColor.color,
                selected: settings.useHEVC) {
                settings.useHEVC = true
            }
            row(title: "H.264",
                subtitle: "Bigger files · plays on everything",
                icon: "film.fill",
                iconColor: settings.accentColor.color,
                selected: !settings.useHEVC) {
                settings.useHEVC = false
            }
        }
    }

    // MARK: - About

    var aboutSection: some View {
        Section(header: sectionHeader("Good to Know", icon: "info.circle.fill")) {
            aboutRow(icon: "shield.lefthalf.filled",
                     title: "Crash Safe",
                     body: "Saved in fragments — footage survives a dead battery.")
            aboutRow(icon: "moon.fill",
                     title: "Screen Stays On",
                     body: "No background filming on iOS. Use the moon button to dim.")
            aboutRow(icon: "hand.tap.fill",
                     title: "Shortcuts",
                     body: "Double-tap preview to flip cameras. Volume keys = shutter (change this under Capture Assist).")
            aboutRow(icon: "leaf.fill",
                     title: "Longevity Mode",
                     body: "Runs a lighter preview and encoder profile for cooler long sessions.")
            aboutRow(icon: "sparkles",
                     title: "v4 Beta 3",
                     body: "Native 120/240fps capture, adaptive iPhone 11+ layout, and modern rotation.")
        }
    }

    // MARK: - Photo

}
