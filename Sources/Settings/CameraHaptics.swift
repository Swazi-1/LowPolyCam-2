import AVFoundation
import UIKit

/// One place for camera haptic behavior. Views request a haptic; they do not configure AVAudioSession.
enum CameraHaptics {
    private static let light = UIImpactFeedbackGenerator(style: .light)
    private static let medium = UIImpactFeedbackGenerator(style: .medium)
    private static let heavy = UIImpactFeedbackGenerator(style: .heavy)

    static func fire(strength selectedStrength: String? = nil, captureOnly: Bool = false) {
        let defaults = UserDefaults.standard
        if captureOnly, !(defaults.object(forKey: "hapticCaptureEnabled") as? Bool ?? true) { return }

        let strength = selectedStrength ?? defaults.string(forKey: "hapticStrength") ?? "Medium"
        try? AVAudioSession.sharedInstance().setAllowHapticsAndSystemSoundsDuringRecording(true)

        let generator = strength == "Low" ? light : strength == "Strong" ? heavy : medium
        generator.prepare()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
            let intensity: CGFloat = strength == "Low" ? 0.45 : strength == "Strong" ? 1 : 0.7
            generator.impactOccurred(intensity: intensity)
        }
    }
}
