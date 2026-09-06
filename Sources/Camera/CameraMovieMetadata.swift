import AVFoundation
import UIKit
import Darwin

enum CameraMovieMetadata {
    static func items(isSlowMotion: Bool = false) -> [AVMetadataItem] {
        var info = utsname()
        uname(&info)
        let identifier = withUnsafeBytes(of: &info.machine) { bytes in
            String(bytes: bytes.prefix { $0 != 0 }, encoding: .utf8) ?? ""
        }
        let names = [
            "iPhone12,1": "iPhone 11",
            "iPhone12,3": "iPhone 11 Pro",
            "iPhone12,5": "iPhone 11 Pro Max"
        ]
        // Keep the exact hardware identifier when the friendly name is unknown instead of
        // degrading every newer iPhone to the generic string "iPhone".
        let model = names[identifier] ?? (identifier.isEmpty ? UIDevice.current.model : identifier)
        let values: [(AVMetadataIdentifier, String)] = [
            (.quickTimeMetadataMake, "Apple"),
            (.quickTimeMetadataModel, model),
            (.quickTimeMetadataSoftware, "LowPolyCam"),
            (.quickTimeMetadataCreationDate, ISO8601DateFormatter().string(from: Date()))
        ]
        var result: [AVMetadataItem] = values.map { key, value in
            let item = AVMutableMetadataItem()
            item.identifier = key
            item.dataType = kCMMetadataBaseDataType_UTF8 as String
            item.value = value as NSString
            return item
        }

        if isSlowMotion {
            let intent = AVMutableMetadataItem()
            intent.identifier = .quickTimeMetadataFullFrameRatePlaybackIntent
            // 0 tells players the HFR movie is intended for slow-motion playback.
            intent.value = NSNumber(value: 0)
            result.append(intent)
        }
        return result
    }
}
