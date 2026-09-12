import Foundation
import OS

enum CameraPerformanceIntervalName {
    case sessionConfiguration
    case sessionStart
    case modeSwitch
    case captureTransaction
    case physicalInputReplacement
    case photoRequest
    case recordingStart

    var signpostName: StaticString {
        switch self {
        case .sessionConfiguration: return "SessionConfiguration"
        case .sessionStart: return "SessionStart"
        case .modeSwitch: return "ModeSwitch"
        case .captureTransaction: return "CaptureTransaction"
        case .physicalInputReplacement: return "PhysicalInputReplacement"
        case .photoRequest: return "PhotoRequest"
        case .recordingStart: return "RecordingStart"
        }
    }
}

struct CameraPerformanceInterval {
    let name: CameraPerformanceIntervalName
    let state: OSSignpostIntervalState
}

final class CameraPerformanceMonitor {
    static let shared = CameraPerformanceMonitor()

    private let signposter = OSSignposter(
        subsystem: "com.swazi.lowpolycam",
        category: "CameraPerformance"
    )

    private init() {}

    func begin(_ name: CameraPerformanceIntervalName) -> CameraPerformanceInterval? {
        guard signposter.isEnabled else { return nil }
        let id = signposter.makeSignpostID()
        return CameraPerformanceInterval(
            name: name,
            state: signposter.beginInterval(name.signpostName, id: id)
        )
    }

    func end(_ interval: CameraPerformanceInterval?) {
        guard let interval else { return }
        signposter.endInterval(interval.name.signpostName, interval.state)
    }
}
