import AVFoundation

/// Timestamp gaps in the last saved clip, not a live preview/encoder drop counter.
enum ClipFrameDiagnostics {
    private static let queue = DispatchQueue(label: "com.swazi.lowpolycam.frameDiagnostics", qos: .utility)
    private static let batchSize = 512

    static func inspect(_ url: URL, completion: @escaping (Int?) -> Void) {
        let traceID = AppEventLog.extremeDiagnosticsEnabled ? AppEventLog.makeTraceID("CLIP-FRAMES") : nil
        let queuedAt = ProcessInfo.processInfo.systemUptime
        AppEventLog.deepEvent("CLIP FRAME INSPECTION QUEUED", category: .recording, traceID: traceID,
                              fields: ["file": url.lastPathComponent])
        queue.async {
            let startedAt = ProcessInfo.processInfo.systemUptime
            do {
                let asset = AVURLAsset(url: url)
                guard let track = asset.tracks(withMediaType: .video).first else {
                    AppEventLog.event("CLIP FRAME INSPECTION FAILED", category: .recording, level: .warning, traceID: traceID,
                                      fields: ["reason": "no video track"])
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

                var expectedCadence = track.nominalFrameRate > 0 ? 1.0 / Double(track.nominalFrameRate) : 0
                var batch: [Double] = []
                batch.reserveCapacity(batchSize)
                var previousTime: Double?
                var gapCount = 0
                var validIntervals = 0

                func consumeBatch() {
                    guard !batch.isEmpty else { return }
                    batch.sort()
                    if expectedCadence <= 0, batch.count > 2 {
                        let intervals = zip(batch.dropFirst(), batch).map { $0.0 - $0.1 }.filter { $0 > 0 }
                        if !intervals.isEmpty {
                            let sorted = intervals.sorted()
                            expectedCadence = sorted[sorted.count / 2]
                        }
                    }

                    for time in batch {
                        if let previousTime {
                            let interval = time - previousTime
                            if interval > 0, expectedCadence > 0 {
                                validIntervals += 1
                                if interval > expectedCadence * 1.5 {
                                    gapCount += max(0, Int((interval / expectedCadence).rounded()) - 1)
                                }
                            }
                        }
                        previousTime = time
                    }
                    batch.removeAll(keepingCapacity: true)
                }

                while let time = autoreleasepool(invoking: { () -> Double? in
                    guard let sample = output.copyNextSampleBuffer() else { return nil }
                    return CMSampleBufferGetPresentationTimeStamp(sample).seconds
                }) {
                    if time.isFinite {
                        batch.append(time)
                        if batch.count >= batchSize { consumeBatch() }
                    }
                }
                consumeBatch()

                guard reader.status == .completed, validIntervals > 1 else {
                    completion(nil)
                    return
                }
                AppEventLog.deepEvent("CLIP FRAME INSPECTION COMPLETE", category: .recording, traceID: traceID, fields: [
                    "gapCount": String(gapCount),
                    "validIntervals": String(validIntervals),
                    "nominalFPS": String(format: "%.2f", track.nominalFrameRate),
                    "expectedCadenceMs": String(format: "%.3f", expectedCadence * 1000),
                    "queueWaitMs": String(format: "%.2f", (startedAt - queuedAt) * 1000),
                    "workMs": String(format: "%.2f", (ProcessInfo.processInfo.systemUptime - startedAt) * 1000)
                ])
                completion(gapCount)
            } catch {
                AppEventLog.log(error: error, prefix: "CLIP FRAME INSPECTION ERROR", category: .recording, traceID: traceID)
                completion(nil)
            }
        }
    }
}
