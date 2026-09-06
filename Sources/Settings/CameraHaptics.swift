import AVFAudio
import Foundation
import UIKit

/// One place for camera haptic behavior. AVAudioSession policy is configured with the camera
/// session; individual taps only prepare and fire the selected feedback generator.
enum CameraHaptics {
    private static let light = UIImpactFeedbackGenerator(style: .light)
    private static let medium = UIImpactFeedbackGenerator(style: .medium)
    private static let heavy = UIImpactFeedbackGenerator(style: .heavy)

    /// AVCaptureSession may activate an audio-recording session for the microphone. iOS defaults
    /// to suppressing system haptics while audio input is active, so establish the policy before
    /// capture starts and reassert it after session/recovery changes. This does not change the
    /// app's audio category, route, or activation state.
    static func prepareSystemPolicy() {
        let session = AVAudioSession.sharedInstance()
        guard !session.allowHapticsAndSystemSoundsDuringRecording else { return }
        try? session.setAllowHapticsAndSystemSoundsDuringRecording(true)
    }

    static func fire(strength selectedStrength: String? = nil, captureOnly: Bool = false) {
        let defaults = UserDefaults.standard
        if captureOnly, !(defaults.object(forKey: "hapticCaptureEnabled") as? Bool ?? true) { return }

        let strength = selectedStrength ?? defaults.string(forKey: "hapticStrength") ?? "Medium"
        performImpact(strength: strength)
    }

    /// Settings preview is separate from capture feedback so re-tapping the selected strength
    /// previews it again immediately.
    static func preview(strength: String) {
        performImpact(strength: strength)
    }

    private static func performImpact(strength: String) {
        let perform = {
            prepareSystemPolicy()
            let generator: UIImpactFeedbackGenerator
            switch strength {
            case "Low": generator = light
            case "Strong": generator = heavy
            default: generator = medium
            }
            generator.prepare()
            generator.impactOccurred()
            // Keep the retained generator warm for the next nearby capture/menu tap.
            generator.prepare()
        }
        if Thread.isMainThread {
            perform()
        } else {
            DispatchQueue.main.async(execute: perform)
        }
    }
}

