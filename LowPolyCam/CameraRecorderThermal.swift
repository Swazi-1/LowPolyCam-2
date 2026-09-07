//
//  CameraRecorderThermal.swift
//  LowPolyCam
//
//  Responsibility split from CameraRecorder.swift. Behavior intentionally
//  preserved; these helpers still operate on the same CameraRecorder state.
//

import UIKit

extension CameraRecorder {

    func installThermalMonitoring() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleThermalStateChanged),
            name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        thermalState = ProcessInfo.processInfo.thermalState
    }

    @objc private func handleThermalStateChanged() {
        let state = ProcessInfo.processInfo.thermalState
        Task { @MainActor [weak self] in
            self?.applyThermalState(state)
        }
    }

    func applyThermalState(_ state: ProcessInfo.ThermalState) {
        thermalState = state

        switch state {
        case .critical:
            guard !appliedThermalMitigation else { return }
            appliedThermalMitigation = true

            // Auto-Cooling: dim the screen to cut display power draw.
            // Snapshot current brightness so we can restore it later.
            if thermalSavedBrightness == nil {
                thermalSavedBrightness = UIScreen.main.brightness
            }
            if UIScreen.main.brightness > 0.30 {
                UIScreen.main.brightness = 0.30
            }

            // Brightness alone barely touches the ISP/encoder heat that
            // actually drives A10 into critical — those keep running at
            // whatever the idle preview format currently is. If we're not
            // recording, force preview down to the lowest idle path (720p
            // @ 15fps) regardless of Longevity Mode, on top of the normal
            // idle caps in applyActiveFormat(forRecording:false). This is
            // skipped while actively recording so we never touch the
            // AVAssetWriter session mid-clip; the existing free-space/UI
            // notice is the only feedback during an active recording.
            if !isRecording {
                sessionQueue.async { [weak self] in
                    self?.applyActiveFormat(forRecording: false, forceLowestIdlePreview: true)
                    self?.applyStabilization()
                }
            }
            notice = "Phone is hot · Cooling down"

        case .serious:
            // Keep this separate from the critical-state flag below. A later
            // .critical notification must still apply the stronger preview
            // throttle and 30% brightness cap.
            if !appliedThermalMitigation {
                if thermalSavedBrightness == nil {
                    thermalSavedBrightness = UIScreen.main.brightness
                }
                if UIScreen.main.brightness > 0.45 {
                    UIScreen.main.brightness = 0.45
                }
                notice = "Phone is warm"
            }

        case .nominal, .fair:
            // Serious heat only dims the screen; it does not set the critical
            // preview-throttle flag. Restore whenever we own a saved brightness
            // snapshot so a serious-only event cannot leave the display dimmed.
            if appliedThermalMitigation || thermalSavedBrightness != nil {
                appliedThermalMitigation = false
                // Restore pre-thermal brightness (if we were the ones who dimmed it).
                if let saved = thermalSavedBrightness {
                    UIScreen.main.brightness = saved
                    thermalSavedBrightness = nil
                }
                if !isRecording {
                    sessionQueue.async { [weak self] in
                        self?.applyActiveFormat(forRecording: false)
                        self?.applyStabilization()
                    }
                }
            }

        @unknown default:
            break
        }
    }
}
