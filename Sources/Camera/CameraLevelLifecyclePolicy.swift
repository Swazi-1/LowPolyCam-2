import Foundation

/// Pure startup/health decisions for the level-meter stream. Kept outside Core Motion so launch
/// recovery can be regression-tested on non-iOS CI instead of relying on a real motion sensor.
enum CameraLevelLifecyclePolicy {
    static let maximumStartupRetries = 3
    static let startupRetryDelay: TimeInterval = 0.45
    static let healthCheckInterval: TimeInterval = 0.75
    static let staleDeliveryInterval: TimeInterval = 1.35

    static func shouldRetryStartup(
        wantsMonitoring: Bool,
        receivedValidSample: Bool,
        retryCount: Int
    ) -> Bool {
        wantsMonitoring && !receivedValidSample && retryCount < maximumStartupRetries
    }

    static func streamIsStale(now: TimeInterval, lastDelivery: TimeInterval?) -> Bool {
        guard now.isFinite, let lastDelivery, lastDelivery.isFinite else { return true }
        return now - lastDelivery > staleDeliveryInterval
    }
}
