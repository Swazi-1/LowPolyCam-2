import AVFoundation

/// Timestamp gaps in the last saved clip, not a live preview/encoder drop counter.
enum ClipFrameDiagnostics {
    private static let queue = DispatchQueue(label: "com.swazi.lowpolycam.frameDiagnostics", qos: .utility)

    static func inspect(_ url: URL, completion: @escaping (Int?) -> Void) {
        queue.async {
            do {
                let asset = AVURLAsset(url: url)
                guard let track = asset.tracks(withMediaType: .video).first else { completion(nil); return }
                let reader = try AVAssetReader(asset: asset)
                let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
                output.alwaysCopiesSampleData = false
                guard reader.canAdd(output) else { completion(nil); return }
                reader.add(output)
                guard reader.startReading() else { completion(nil); return }
                var times: [Double] = []
                while let time = autoreleasepool(invoking: { () -> Double? in
                    guard let sample = output.copyNextSampleBuffer() else { return nil }
                    return CMSampleBufferGetPresentationTimeStamp(sample).seconds
                }) {
                    if time.isFinite { times.append(time) }
                }
                guard reader.status == .completed, times.count > 2 else { completion(nil); return }
                times.sort() // Compressed B-frames may arrive in decode order.
                let intervals = zip(times.dropFirst(), times).map(-)
                let sorted = intervals.filter { $0 > 0 }.sorted()
                guard !sorted.isEmpty else { completion(nil); return }
                let cadence = sorted[sorted.count / 2]
                let gaps = intervals.reduce(0) { $0 + ($1 > cadence * 1.5 ? max(0, Int(($1 / cadence).rounded()) - 1) : 0) }
                completion(gaps)
            } catch { completion(nil) }
        }
    }
}
