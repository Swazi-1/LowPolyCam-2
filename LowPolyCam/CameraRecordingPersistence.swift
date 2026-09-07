import AVFoundation
import UIKit
import Photos
import MediaPlayer
import CoreMotion
import AudioToolbox
import ImageIO
import VideoToolbox

extension CameraRecorder {

    func recoverInterruptedRecording() {
        var entries = RecordingRecoveryJournal.entries
        if let legacy = UserDefaults.standard.string(forKey: Self.inProgressKey), entries[legacy] == nil {
            entries[legacy] = UserDefaults.standard.string(forKey: Self.inProgressDestinationKey) ?? SaveLocation.files.rawValue
        }
        for (name, rawDestination) in entries {
            guard name == URL(fileURLWithPath: name).lastPathComponent else { continue }
            let url = Self.clipsDirectory.appendingPathComponent(name)
            Task {
                let asset = AVURLAsset(url: url)
                let playable = (try? await asset.load(.isPlayable)) ?? false
                guard playable else {
                    await MainActor.run { self.notice = "Interrupted recording kept in Files for recovery" }
                    continueRecovery(url)
                    return
                }
                generateThumbnail(for: url)
                deliver(url, to: SaveLocation(rawValue: rawDestination) ?? .files) {
                    RecordingRecoveryJournal.remove(url)
                }
            }
        }
    }

    private func continueRecovery(_ url: URL) {
        // Retain damaged bytes; do not repeatedly attempt a Photos import.
        RecordingRecoveryJournal.remove(url)
    }

    // MARK: Delivering finished clips & Thumbnails

    func generateThumbnail(for url: URL) {
        DispatchQueue.global(qos: .utility).async {
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 140, height: 140)
            let time = CMTime(seconds: 0.5, preferredTimescale: 600)
            if let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) {
                let img = UIImage(cgImage: cgImage)
                Task { @MainActor in
                    self.lastClipThumbnail = img
                    self.lastClipURL = url
                }
            } else if let cgImage = try? generator.copyCGImage(at: .zero, actualTime: nil) {
                let img = UIImage(cgImage: cgImage)
                Task { @MainActor in
                    self.lastClipThumbnail = img
                    self.lastClipURL = url
                }
            }
        }
    }

    func ensurePhotosAccess() {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if status == .notDetermined {
            Task { _ = await PHPhotoLibrary.requestAuthorization(for: .addOnly) }
        }
        // Denied is handled by deliver() — clip is kept in Files, no crash.
    }

    func deliver(_ url: URL, to destination: SaveLocation, done: @escaping () -> Void) {
        guard destination == .photos else {
            Task { @MainActor in self.notice = "Saved to Files" }
            done()
            return
        }

        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        guard status == .authorized || status == .limited else {
            Task { @MainActor in
                self.notice = "Saved to Files (Photo access denied)"
            }
            done()
            return
        }

        func attemptSave(isRetry: Bool) {
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.shouldMoveFile = false
                options.originalFilename = url.lastPathComponent
                request.addResource(with: .video, fileURL: url, options: options)
            } completionHandler: { [weak self] success, error in
                if success {
                    Task { @MainActor in
                        self?.notice = "Saved to Photos"
                    }
                    done()
                    return
                }
                // One retry after a short delay — intermittent Photos import
                // failures are common under thermal/storage pressure on iOS 15.
                if !isRetry {
                    DebugLog.write("⚠️ Photos save failed, retrying once: \(error?.localizedDescription ?? "?")")
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.6) {
                        attemptSave(isRetry: true)
                    }
                    return
                }
                DebugLog.write("❌ Photos save failed after retry: \(error?.localizedDescription ?? "?")")
                Task { @MainActor in
                    self?.notice = "Saved to Files (Photos refused)"
                }
                done()
            }
        }
        attemptSave(isRetry: false)
    }

    /// After a successful Photos import, remove local video clips from the
    /// app Documents directory so storage stays low (the intended behaviour
    /// when the user chose "Save to Photos"). Photos themselves are safe in
    /// the library; only our temporary/local copies are removed.
    func cleanupLocalClipsAfterPhotosSave(keeping currentURL: URL?) {
        DispatchQueue.global(qos: .background).async {
            let fm = FileManager.default
            guard let files = try? fm.contentsOfDirectory(at: Self.clipsDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return }
            for file in files {
                let ext = file.pathExtension.lowercased()
                guard ext == "mov" || ext == "mp4" else { continue }
                if let current = currentURL, file.lastPathComponent == current.lastPathComponent {
                    continue
                }
                try? fm.removeItem(at: file)
            }
        }
    }

    func loadLastSavedClip() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let fm = FileManager.default
            guard let files = try? fm.contentsOfDirectory(at: Self.clipsDirectory, includingPropertiesForKeys: [.creationDateKey, .fileSizeKey], options: [.skipsHiddenFiles]) else { return }
            let validClips = files.filter { url in
                let ext = url.pathExtension.lowercased()
                return ext == "mov" || ext == "mp4"
            }.sorted { (u1, u2) -> Bool in
                let d1 = (try? u1.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                let d2 = (try? u2.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                return d1 > d2
            }

            if let latest = validClips.first {
                let size = (try? latest.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                if size > 0 {
                    self.generateThumbnail(for: latest)
                }
            }
        }
    }

    // MARK: Storage

    func refreshFreeSpace() {
        DispatchQueue.global(qos: .utility).async {
            let url = URL(fileURLWithPath: NSHomeDirectory())
            let bytes = (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
                .volumeAvailableCapacityForImportantUsage ?? 0
            self.ioQueue.async { self.freeBytesSnapshot = Int64(bytes) }
            Task { @MainActor in self.freeBytes = Int64(bytes) }
        }
    }

    static var clipsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static func newClipURL() -> URL {
        clipsDirectory.appendingPathComponent(CaptureFileNamer.nextFileName(extension: "mov"))
    }

    // MARK: Video Matrix Orientation

    static func transform(width: Int, height: Int, isFront: Bool, mirrorFront: Bool, angle: CGFloat = 90) -> CGAffineTransform {
        var rotation = CGAffineTransform(rotationAngle: angle * .pi / 180)
        let bounds = CGRect(x: 0, y: 0, width: width, height: height).applying(rotation)
        rotation.tx -= bounds.minX
        rotation.ty -= bounds.minY
        if isFront && mirrorFront {
            rotation = rotation.concatenating(CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: bounds.width, ty: 0))
        }
        return rotation
    }

    enum RecorderError: LocalizedError {
        case cannotAddInput
        var errorDescription: String? { "Encoder rejected format settings" }
    }
}
