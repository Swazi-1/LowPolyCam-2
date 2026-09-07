import Foundation

/// Pure level-meter math kept separate from Core Motion / SwiftUI so its cardinal-orientation
/// behavior can be regression-tested on non-iOS CI.
enum CameraLevelMath {
    static let minimumHorizonStrength = 0.06

    /// Returns a continuous visual tilt in -45°...45° that is exactly horizontal at every
    /// cardinal device orientation (0°/90°/180°/270°). The folded sine avoids the old abrupt
    /// nearest-quadrant snap when the phone passes roughly 45°.
    static func indicatorAngle(gravityX: Double, gravityY: Double) -> Double? {
        guard gravityX.isFinite, gravityY.isFinite else { return nil }
        guard hypot(gravityX, gravityY) > minimumHorizonStrength else { return nil }

        let roll = atan2(gravityX, -gravityY)
        let folded = sin(2 * roll)
        return 0.5 * asin(min(1, max(-1, folded)))
    }

    static func smooth(current: Double, target: Double, response: Double = 0.42) -> Double {
        guard current.isFinite, target.isFinite else { return target.isFinite ? target : 0 }
        let amount = min(1, max(0, response))
        return current + (target - current) * amount
    }
}
