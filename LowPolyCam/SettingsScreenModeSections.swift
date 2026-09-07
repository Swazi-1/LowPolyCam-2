import SwiftUI

extension SettingsScreen {

    var photoMegapixelsSection: some View {
        Section(header: sectionHeader("Photo Size", icon: "camera.fill"),
                footer: Text("Captured at full sensor resolution, then saved at the size you pick. Lower MP uses less storage.")) {
            // Only show sizes this lens can deliver (front camera often maxes ~7 MP).
            let mpItems = availablePhotoMegapixels.isEmpty ? PhotoMegapixels.allCases : availablePhotoMegapixels
            chipRow(mpItems.map { mp in
                ChipItem(id: "mp-\(mp.id)", label: mp.label,
                         selected: settings.photoMegapixels == mp) {
                    settings.photoMegapixels = mp
                }
            })
        }
    }

    // MARK: - Photo 2.0: Burst, format, aspect, review

    var photoBurstSection: some View {
        Section(header: sectionHeader("Burst Mode", icon: "square.stack.3d.up.fill"),
                footer: Text("Press and hold the shutter to fire a burst. A quick tap still takes a single photo.")) {
            chipRow(BurstCount.allCases.map { count in
                ChipItem(id: "burst-\(count.id)", label: "\(count.label) photos",
                         selected: settings.burstCount == count) {
                    settings.burstCount = count
                }
            })
        }
    }

    var photoFormatSection: some View {
        Section(header: sectionHeader("Format & Framing", icon: "square.on.square")) {
            SettingsPickerRow(
                title: "File format",
                icon: "doc.fill",
                accentColor: settings.accentColor.color,
                selection: $settings.photoFormat,
                label: { Text($0.label) }
            )
            SettingsPickerRow(
                title: "Aspect ratio",
                icon: "crop",
                accentColor: settings.accentColor.color,
                selection: $settings.photoAspect,
                label: { Text($0.label) }
            )
            Toggle(isOn: $settings.photoReviewAfterCapture) {
                Label("Review after capture", systemImage: "eye.fill")
                    .labelStyle(SettingsLabelStyle(color: settings.accentColor.color))
            }
            .onChange(of: settings.photoReviewAfterCapture) { _, _ in
                fireSettingsToggleHaptic(settings)
            }
        }
    }

    // MARK: - Slow-Mo

    var slowMoFrameRateSection: some View {
        Section(header: sectionHeader("Slow-Mo Speed", icon: "tortoise.fill"),
                footer: Text(isSlowMoSupported
                             ? "Higher fps = smoother, slower playback."
                             : "Slow motion is not available on this camera lens.")) {
            chipRow(SlowMoFrameRate.allCases.map { rate in
                let available = availableSlowMoRates.contains(rate)
                return ChipItem(id: "sm-\(rate.id)", label: "\(rate.label) (\(rate.multiplierLabel))",
                                 enabled: available,
                                 selected: settings.slowMoFrameRate == rate) {
                    settings.slowMoFrameRate = rate
                    recorder.updateCaptureFormat()
                }
            })
        }
    }

    var slowMoResolutionSection: some View {
        Section(header: sectionHeader("Slow-Mo Resolution", icon: "rectangle.dashed"),
                footer: Text("Some frame rates limit the maximum resolution on this iPhone.")) {
            chipRow(Resolution.allCases.filter { $0 != .p2160 }.map { r in
                let available = availableSlowMoResolutions.contains(r)
                return ChipItem(id: r.id, label: r.label,
                                 enabled: available,
                                 selected: settings.slowMoResolution == r) {
                    settings.slowMoResolution = r
                }
            })
        }
    }

    // MARK: - Compact chip picker

    struct ChipItem: Identifiable {
        let id: String
        let label: String
        var enabled: Bool = true
        var selected: Bool = false
        let action: () -> Void
    }

    func chipRow(_ items: [ChipItem]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(items) { item in
                    Button(action: {
                        guard item.enabled else { return }
                        if settings.hapticFeedbackEnabled { presetHaptic.selectionChanged() }
                        item.action()
                    }) {
                        HStack(spacing: 4) {
                            Text(item.label)
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                            if !item.enabled {
                                Image(systemName: "lock.fill")
                                    .font(.system(size: 9, weight: .bold))
                            }
                        }
                        .foregroundColor(
                            item.selected && item.enabled ? .white
                            : (item.enabled ? .primary : .secondary.opacity(0.5))
                        )
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(
                            Capsule()
                                .fill(item.selected && item.enabled
                                      ? settings.accentColor.color
                                      : Color.secondary.opacity(0.12))
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(!item.enabled)
                }
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: - Building blocks

    func sectionHeader(_ title: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(settings.accentColor.color)
            Text(title)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .textCase(nil)
        }
    }

    func row(title: String,
                     subtitle: String,
                     icon: String? = nil,
                     iconColor: Color? = nil,
                     selected: Bool,
                     enabled: Bool = true,
                     tap: @escaping () -> Void) -> some View {
        Button(action: {
            guard enabled else { return }
            if settings.hapticFeedbackEnabled {
                presetHaptic.selectionChanged()
            }
            tap()
        }) {
            HStack(spacing: 12) {
                if let icon = icon, let color = iconColor {
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 28, height: 28)
                        .background(enabled ? color : Color.gray.opacity(0.3))
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .foregroundColor(enabled ? .primary : .secondary)
                    Text(subtitle)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 4)
                if selected && enabled {
                    Image(systemName: "checkmark")
                        .foregroundColor(settings.accentColor.color)
                        .font(.system(size: 15, weight: .bold))
                } else if !enabled {
                    Image(systemName: "lock.fill")
                        .foregroundColor(.secondary.opacity(0.4))
                        .font(.system(size: 12))
                }
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 15, weight: .regular, design: .rounded))
            Spacer()
            Text(value)
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    func aboutRow(icon: String, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(settings.accentColor.bright)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                Text(body)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }

}
