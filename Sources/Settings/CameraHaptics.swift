import Foundation
import UIKit

/// One place for camera haptic behavior. AVAudioSession policy is configured with the camera
/// session; individual taps only prepare and fire the selected feedback generator.
enum CameraHaptics {
    private static let light = UIImpactFeedbackGenerator(style: .light)
    private static let medium = UIImpactFeedbackGenerator(style: .medium)
    private static let heavy = UIImpactFeedbackGenerator(style: .heavy)

    static func fire(strength selectedStrength: String? = nil, captureOnly: Bool = false) {
        let defaults = UserDefaults.standard
        if captureOnly, !(defaults.object(forKey: "hapticCaptureEnabled") as? Bool ?? true) { return }

        let strength = selectedStrength ?? defaults.string(forKey: "hapticStrength") ?? "Medium"
        let perform = {
            let generator = strength == "Low" ? light : strength == "Strong" ? heavy : medium
            let intensity: CGFloat = strength == "Low" ? 0.45 : strength == "Strong" ? 1 : 0.7
            generator.prepare()
            generator.impactOccurred(intensity: intensity)
        }
        if Thread.isMainThread {
            perform()
        } else {
            DispatchQueue.main.async(execute: perform)
        }
    }
}
