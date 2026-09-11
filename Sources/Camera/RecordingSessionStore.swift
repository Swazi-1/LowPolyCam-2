import Foundation

struct RecordingSessionSegment: Codable {
    let sessionID: String
    let segmentIndex: Int
    let filename: String
    let mode: String
    let cameraPosition: String
    let resolution: String
    let frameRate: Double
    let codec: String
    let compression: String
    let duration: Double
    let recordedAt: Date
}

/// Keeps split segments grouped even though each segment remains a normal Photos asset. The
/// manifest lives outside the temporary MOV path, so it survives Photos moving the source file.
enum RecordingSessionStore {
    private static let directoryName = "Recording Sessions"
    private static let queue = DispatchQueue(label: "com.swazi.lowpolycam.recordingSessions", qos: .utility)
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    static func record(_ segment: RecordingSessionSegment) {
        queue.async {
            guard let directory = directory else { return }
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let url = directory.appendingPathComponent("\(segment.sessionID).json")
                var segments = (try? Data(contentsOf: url)).flatMap { try? decoder.decode([RecordingSessionSegment].self, from: $0) } ?? []
                segments.removeAll { $0.segmentIndex == segment.segmentIndex }
                segments.append(segment)
                segments.sort { $0.segmentIndex < $1.segmentIndex }
                let data = try encoder.encode(segments)
                try data.write(to: url, options: [.atomic])
                AppEventLog.deepEvent("RECORDING SESSION MANIFEST UPDATED", category: .recording, fields: [
                    "sessionID": segment.sessionID,
                    "segment": String(segment.segmentIndex),
                    "filename": segment.filename
                ])
            } catch {
                AppEventLog.log(error: error, prefix: "RECORDING SESSION MANIFEST FAILED", category: .recording)
            }
        }
    }

    private static var directory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("LowPolyCam/\(directoryName)", isDirectory: true)
    }
}
