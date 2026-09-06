import AVFAudio
import CoreHaptics
import Foundation
import UIKit

/// Central haptic path for camera controls and Settings previews.
/// Core Haptics is the primary engine so strength previews remain explicit and predictable while
/// AVCaptureSession owns an audio-recording session. UIKit impact feedback is retained as fallback.
enum CameraHaptics {
    private static var engine: CHHapticEngine?
    private static let lightImpact = UIImpactFeedbackGenerator(style: .light)
    private static let mediumImpact = UIImpactFeedbackGenerator(style: .medium)
    private static let heavyImpact = UIImpactFeedbackGenerator(style: .heavy)

    /// Audio input suppresses system haptics by default. Keep the documented shared-audio-session
    /// policy enabled without changing LowPolyCam's category, route, or activation state.
    static func prepareSystemPolicy() {
        let session = AVAudioSession.sharedInstance()
        guard !session.allowHapticsAndSystemSoundsDuringRecording else { return }
        do {
            try session.setAllowHapticsAndSystemSoundsDuringRecording(true)
        } catch {
            // Core Haptics/UIKit fallback is still attempted. Camera audio configuration must not
            // be changed merely to make a Settings preview vibrate.
        }
    }

    static func fire(strength selectedStrength: String? = nil, captureOnly: Bool = false) {
        let defaults = UserDefaults.standard
        if captureOnly, !(defaults.object(forKey: "hapticCaptureEnabled") as? Bool ?? true) { return }
        let strength = selectedStrength ?? defaults.string(forKey: "hapticStrength") ?? "Medium"
        perform(strength: strength)
    }

    /// Re-tapping the selected strength intentionally previews it again.
    static func preview(strength: String) {
        perform(strength: strength)
    }

    private static func perform(strength: String) {
        let work = {
            prepareSystemPolicy()
            if playCoreHaptic(strength: strength) { return }
            playUIKitFallback(strength: strength)
        }
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    @discardableResult
    private static func playCoreHaptic(strength: String) -> Bool {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return false }

        do {
            let hapticEngine: CHHapticEngine
            if let existing = engine {
                hapticEngine = existing
            } else {
                let created = try CHHapticEngine()
                created.isAutoShutdownEnabled = false
                created.resetHandler = {
                    DispatchQueue.main.async {
                        engine = nil
                        _ = ensureEngineStarted()
                    }
                }
                created.stoppedHandler = { _ in
                    DispatchQueue.main.async { engine = nil }
                }
                engine = created
                hapticEngine = created
            }

            try hapticEngine.start()
            let values = coreHapticValues(for: strength)
            let event = CHHapticEvent(
                eventType: .hapticTransient,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: values.intensity),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: values.sharpness)
                ],
                relativeTime: 0
            )
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            let player = try hapticEngine.makePlayer(with: pattern)
            try player.start(atTime: CHHapticTimeImmediate)
            return true
        } catch {
            engine = nil
            return false
        }
    }

    private static func ensureEngineStarted() -> Bool {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return false }
        do {
            let created = try CHHapticEngine()
            created.isAutoShutdownEnabled = false
            try created.start()
            engine = created
            return true
        } catch {
            engine = nil
            return false
        }
    }

    private static func coreHapticValues(for strength: String) -> (intensity: Float, sharpness: Float) {
        switch strength {
        case "Low": return (0.32, 0.38)
        case "Strong": return (1.0, 0.72)
        default: return (0.62, 0.52)
        }
    }

    private static func playUIKitFallback(strength: String) {
        let generator: UIImpactFeedbackGenerator
        switch strength {
        case "Low": generator = lightImpact
        case "Strong": generator = heavyImpact
        default: generator = mediumImpact
        }
        generator.prepare()
        generator.impactOccurred(intensity: 1.0)
        generator.prepare()
    }
}
