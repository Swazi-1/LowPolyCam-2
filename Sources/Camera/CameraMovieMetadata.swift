import AVFoundation
import UIKit
import Darwin

enum CameraMovieMetadata {
    static func items() -> [AVMetadataItem] {
        var info = utsname()
        uname(&info)
        let identifier = withUnsafeBytes(of: &info.machine) { bytes in
            String(bytes: bytes.prefix { $0 != 0 }, encoding: .utf8) ?? ""
        }
        let names = ["iPhone12,1": "iPhone 11", "iPhone12,3": "iPhone 11 Pro", "iPhone12,5": "iPhone 11 Pro Max"]
        let model = names[identifier] ?? UIDevice.current.model
        let values: [(AVMetadataIdentifier, String)] = [
            (.quickTimeMetadataMake, "Apple"),
            (.quickTimeMetadataModel, model),
            (.quickTimeMetadataSoftware, "LowPolyCam"),
            (.quickTimeMetadataCreationDate, ISO8601DateFormatter().string(from: Date()))
        ]
        return values.map { key, value in
            let item = AVMutableMetadataItem()
            item.identifier = key
            item.dataType = kCMMetadataBaseDataType_UTF8 as String
            item.value = value as NSString
            return item
        }
    }
}
