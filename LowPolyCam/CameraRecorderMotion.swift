//
//  CameraRecorderMotion.swift
//  LowPolyCam
//
//  Responsibility split from CameraRecorder.swift. Behavior intentionally
//  preserved; these helpers still operate on the same CameraRecorder state.
//

import CoreMotion

extension CameraRecorder {

    func startMotionUpdates() {
        guard motionManager.isDeviceMotionAvailable else { return }
        lastRawRollAngle = nil
        // Adaptive rate: full rate only when the level-gauge UI is visible;
        // otherwise a slow trickle is enough for orientation (photo upright
        // + UI rotation). Longevity Mode trims both further — CoreMotion
        // polling is a small but constant power draw for as long as the
        // camera is open. See PerformanceProfile.motionUpdateHz.
        let hz = PerformanceProfile.current(settings: settings, thermalState: thermalState)
            .motionUpdateHz(gaugeVisible: settings.showLevelGauge)
        motionManager.deviceMotionUpdateInterval = 1.0 / hz
        motionManager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: .main) { [weak self] motion, _ in
            guard let self = self, let motion = motion else { return }
            let gx = motion.gravity.x
            let gy = motion.gravity.y
            let gz = motion.gravity.z

            // atan2(gx, -gy) reads rotation *around the z-axis* (screen facing
            // you dead-on). That's only meaningful when the phone is roughly
            // upright. Point the camera steeply up or down — aiming up at a
            // shelf, or flat on a desk — and gx/gy both collapse toward zero
            // while gz dominates; at that point atan2 is amplifying sensor
            // noise, not measuring orientation, and can snap to *any* of the
            // four quadrants almost at random. That's what produced photos
            // saved sideways/upside-down when shot at a steep tilt: the last
            // noisy reading just happened to land in the wrong 90° bucket.
            // Guard: only trust the reading once the horizontal gravity
            // component is large enough to actually distinguish portrait
            // from landscape. Below that, keep the last known-good
            // orientation rather than following the noise.
            let horizontalMagnitude = (gx * gx + gy * gy).squareRoot()
            guard horizontalMagnitude > 0.35 else { return }
            _ = gz // (kept for clarity of the guard's reasoning above)

            let angle = atan2(gx, -gy) * (180.0 / .pi)

            let absAngle = abs(angle)
            let newOrientation: PhysicalOrientation
            if absAngle < 45 {
                newOrientation = .portrait
            } else if angle >= 45 && angle < 135 {
                newOrientation = .landscapeLeft
            } else if angle <= -45 && angle > -135 {
                newOrientation = .landscapeRight
            } else {
                newOrientation = .portraitUpsideDown
            }

            let targetUIAngle = newOrientation.rotationAngle
            if self.physicalOrientation != newOrientation {
                self.physicalOrientation = newOrientation
                self.uiRotationAngle = targetUIAngle
            }

            if let last = self.lastRawRollAngle {
                var delta = angle - last
                if delta > 180 { delta -= 360 }
                if delta < -180 { delta += 360 }
                self.unwrappedRollAngle += delta
            } else {
                self.unwrappedRollAngle = angle
            }
            self.lastRawRollAngle = angle

            // Throttle Observable rollAngle updates to avoid rebuilding the
            // entire camera UI at 6 Hz on A10. Publish when the gauge is on
            // and the angle moved enough to matter visually.
            let newUnwrapped = self.unwrappedRollAngle
            if self.settings.showLevelGauge {
                if abs(newUnwrapped - self.rollAngle) >= 0.5 {
                    self.rollAngle = newUnwrapped
                }
            }
            let remainder = abs(angle.truncatingRemainder(dividingBy: 90))
            let isLevelNow = remainder < 1.2 || remainder > 88.8
            if self.isLevel != isLevelNow {
                self.isLevel = isLevelNow
            }
        }
    }

    func refreshMotionUpdateRate() {
        guard motionManager.isDeviceMotionAvailable else { return }
        let hz = PerformanceProfile.current(settings: settings, thermalState: thermalState)
            .motionUpdateHz(gaugeVisible: settings.showLevelGauge)
        motionManager.deviceMotionUpdateInterval = 1.0 / hz
    }

    func stopMotionUpdates() {
        motionManager.stopDeviceMotionUpdates()
        lastRawRollAngle = nil
    }
}
