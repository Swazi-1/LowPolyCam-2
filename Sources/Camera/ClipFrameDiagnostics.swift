import AVFoundation

/// Timestamp gaps in the last saved clip, not a live preview/encoder drop counter.
enum ClipFrameDiagnostics {
    private static let queue = DispatchQueue(label: "com.swazi.lowpolycam.frameDiagnostics", qos: .utility)

    static func inspect(_ url: URL, completion: @escaping (Int?) -> Void) {
        queue.async {
            do {
                let asset = AVURLAsset(url: url)
                guard let track = asset.tracks(withMediaType: .video).first else {
                    completion(nil)
                    return
                }

                let reader = try AVAssetReader(asset: asset)
                let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
                output.alwaysCopiesSampleData = false
                guard reader.canAdd(output) else {
                    completion(nil)
                    return
                }
                reader.add(output)
                guard reader.startReading() else {
                    completion(nil)
                    return
                }

                var counter = ClipFrameGapCounter(nominalFrameRate: Double(track.nominalFrameRate))

                while let time = autoreleasepool(invoking: { () -> Double? in
                    guard let sample = output.copyNextSampleBuffer() else { return nil }
                    return CMSampleBufferGetPresentationTimeStamp(sample).seconds
                }) {
                    counter.append(time)
                }

                guard reader.status == .completed else {
                    completion(nil)
                    return
                }
                completion(counter.result())
            } catch {
                completion(nil)
            }
        }
    }
}
