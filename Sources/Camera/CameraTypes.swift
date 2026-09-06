import AVFoundation
import Foundation

/// Small public-facing camera models kept out of CameraManager so the manager can focus on
/// coordinating AVCaptureSession work instead of also defining UI/settings data types.
extension CameraManager {
    enum CaptureMode: String, CaseIterable, Identifiable {
        case video = "VIDEO"
        case photo = "PHOTO"
        case sloMo = "SLO-MO"

        var id: String { rawValue }
    }

    enum SlowMotionFrameRate: Int, CaseIterable, Identifiable {
        case fps120 = 120
        case fps240 = 240

        var id: Int { rawValue }
        var label: String { "\(rawValue) fps" }
    }

    enum CameraPosition {
        case back
        case front

        var avPosition: AVCaptureDevice.Position {
            self == .back ? .back : .front
        }
    }

    enum WhiteBalancePreset: String, CaseIterable, Identifiable {
        case auto = "Auto"
        case daylight = "Daylight"
        case cloudy = "Cloudy"
        case tungsten = "Tungsten"
        case fluorescent = "Fluorescent"

        var id: String { rawValue }

        var temperature: Float? {
            switch self {
            case .auto: return nil
            case .daylight: return 5_500
            case .cloudy: return 6_500
            case .tungsten: return 3_200
            case .fluorescent: return 4_200
            }
        }

        var tint: Float {
            switch self {
            case .fluorescent: return 8
            default: return 0
            }
        }
    }

    struct PhotoResolutionOption: Identifiable, Equatable {
        let id: String
        let label: String
        let dimensions: CMVideoDimensions

        static func == (lhs: PhotoResolutionOption, rhs: PhotoResolutionOption) -> Bool {
            lhs.id == rhs.id
        }
    }
}
