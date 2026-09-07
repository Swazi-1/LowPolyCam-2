//
//  CameraPhoto.swift
//  LowPolyCam
//
//  Updated for iOS 27 / Xcode 27 / Swift 6.4.
//  Swift 6 complete concurrency · Observation · Liquid Glass · RotationCoordinator
//

import AVFoundation
import UIKit
import Photos
import MediaPlayer
import CoreMotion
import AudioToolbox
import ImageIO

// MARK: - Photo 2.0 review model

/// One capture the post-shutter review sheet can show. Photos saved to the
/// app's own Files location have a stable on-disk `url` we can reload
/// directly; photos saved to the system Photos library do not (PHAsset
/// only), so those are represented purely by their in-memory `image`
/// (already downscaled/encoded the same as what was saved).
struct PhotoReviewItem: Identifiable, Equatable {
    let id = UUID()
    let image: UIImage
    let url: URL?
    var assetIdentifier: String? = nil
    let capturedAt = Date()

    static func == (lhs: PhotoReviewItem, rhs: PhotoReviewItem) -> Bool { lhs.id == rhs.id }
}

extension CameraRecorder {

    // MARK: Photo Capture

    /// Center-crops a full-frame still to a 1:1 square when the user has
    /// selected the Square aspect setting. No-op for `.full`. Runs on the
    /// already-downscaled image, so this is cheap even on A10.
    func applyPhotoAspect(_ image: UIImage, square: Bool) -> UIImage {
        guard square, let cg = image.cgImage else { return image }
        let w = cg.width
        let h = cg.height
        let side = min(w, h)
        guard side < w || side < h else { return image }
        let x = (w - side) / 2
        let y = (h - side) / 2
        guard let cropped = cg.cropping(to: CGRect(x: x, y: y, width: side, height: side)) else { return image }
        return UIImage(cgImage: cropped, scale: image.scale, orientation: image.imageOrientation)
    }

    func capturePhoto() {
        capturePhotoInternal(isBurstFrame: false, completion: nil)
    }

    private struct PhotoCaptureRequest {
        let targetMegapixels: Double
        let destination: SaveLocation
        let square: Bool
        let jpeg: Bool
        let mirrored: Bool
        let orientation: PhysicalOrientation
        let isBurstFrame: Bool
    }

    func capturePhotoInternal(isBurstFrame: Bool, completion: (() -> Void)?) {
        guard canCapturePhoto() else {
            completion?()
            return
        }
        guard freeBytes > Self.reserveBytes else {
            notice = "Low storage · Free space needed"
            completion?()
            return
        }

        if settings.saveLocation == .photos { ensurePhotosAccess() }
        suppressVolumeTriggerBriefly(duration: 1.2)
        preparePhotoCaptureUI(isBurstFrame: isBurstFrame)
        let request = makePhotoCaptureRequest(isBurstFrame: isBurstFrame)

        sessionQueue.async {
            let didSwapForStill = self.swapToFullResolutionStillFormatIfNeeded()
            let fireCapture: () -> Void = { [weak self] in
                self?.performPhotoOutputCapture(request,
                                                restorePreviewAfterCapture: didSwapForStill,
                                                completion: completion)
            }
            if didSwapForStill, let device = self.cameraInput?.device {
                self.waitForExposureSettled(device: device, timeout: 0.25, completion: fireCapture)
            } else {
                fireCapture()
            }
        }
    }

    private func canCapturePhoto() -> Bool {
        isSessionRunning && !isCapturingPhoto && !isRecording && !isStartingRecording &&
            !isSaving && !isSwitchingMode && !isSwitchingCamera
    }

    private func preparePhotoCaptureUI(isBurstFrame: Bool) {
        isCapturingPhoto = true
        if !isBurstFrame {
            lastBurstReviewItems = []
            lastPhotoReviewItem = nil
        }
        if settings.hapticFeedbackEnabled && !isBurstFrame {
            let generator = UIImpactFeedbackGenerator(style: settings.hapticIntensity.scaled(.medium))
            generator.prepare()
            generator.impactOccurred()
        }
    }

    private func makePhotoCaptureRequest(isBurstFrame: Bool) -> PhotoCaptureRequest {
        PhotoCaptureRequest(
            targetMegapixels: settings.photoMegapixels.megapixels,
            destination: settings.saveLocation,
            square: settings.photoAspect == .square,
            jpeg: settings.photoFormat == .jpeg,
            mirrored: isFrontCamera && !settings.saveSelfiesUnmirrored,
            orientation: physicalOrientation,
            isBurstFrame: isBurstFrame
        )
    }

    private func swapToFullResolutionStillFormatIfNeeded() -> Bool {
        guard let device = cameraInput?.device,
              let stillFormat = CameraFormatSelector.bestPhotoStillFormat(for: device,
                                                                          maxPreviewHeight: 1080,
                                                                          fps: 30) else {
            return false
        }

        let stillDims = stillFormat.largestStillDimensions
        let currentStill = device.activeFormat.largestStillDimensions
        let stillArea = Int(stillDims.width) * Int(stillDims.height)
        let currentArea = Int(currentStill.width) * Int(currentStill.height)
        guard stillArea > currentArea + 500_000 else { return false }
        guard applyUnifiedHardwareConfiguration(to: device, format: stillFormat, targetFPS: 30) else {
            return false
        }
        lastAppliedFormatKey = nil
        return true
    }

    private func performPhotoOutputCapture(_ request: PhotoCaptureRequest,
                                           restorePreviewAfterCapture: Bool,
                                           completion: (() -> Void)?) {
        let photoSettings = makeAVPhotoSettings(request: request)
        configurePhotoConnection(for: request)

        let processor = PhotoCaptureProcessor(
            targetMegapixels: request.targetMegapixels,
            willCapture: { [weak self] in
                guard let self else { return }
                Task { @MainActor in
                    if self.settings.shutterSoundEnabled { SoundPlayer.play(.shutter) }
                    self.onWillCapturePhoto?()
                }
            },
            completion: { [weak self] image, originalData, metadata, errorMessage in
                self?.handlePhotoCaptureResult(image: image,
                                               originalData: originalData,
                                               metadata: metadata,
                                               errorMessage: errorMessage,
                                               request: request,
                                               photoSettingsID: photoSettings.uniqueID,
                                               restorePreviewAfterCapture: restorePreviewAfterCapture,
                                               completion: completion)
            }
        )
        activePhotoProcessors[photoSettings.uniqueID] = processor
        photoOutput.capturePhoto(with: photoSettings, delegate: processor)
    }

    private func makeAVPhotoSettings(request: PhotoCaptureRequest) -> AVCapturePhotoSettings {
        let photoSettings: AVCapturePhotoSettings
        if photoOutput.availablePhotoCodecTypes.contains(.hevc) {
            photoSettings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
        } else {
            photoSettings = AVCapturePhotoSettings()
        }
        photoSettings.maxPhotoDimensions = photoOutput.maxPhotoDimensions
        photoSettings.flashMode = .off
        photoSettings.photoQualityPrioritization = .quality
        return photoSettings
    }

    private func configurePhotoConnection(for request: PhotoCaptureRequest) {
        guard let connection = photoOutput.connection(with: .video) else { return }
        let rotation = request.orientation.captureVideoRotationAngle
        if connection.isVideoRotationAngleSupported(rotation) {
            connection.videoRotationAngle = rotation
        }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = request.mirrored
        }
    }

    private func handlePhotoCaptureResult(image: UIImage?,
                                          originalData: Data?,
                                          metadata: [String: Any]?,
                                          errorMessage: String?,
                                          request: PhotoCaptureRequest,
                                          photoSettingsID: Int64,
                                          restorePreviewAfterCapture: Bool,
                                          completion: (() -> Void)?) {
        if restorePreviewAfterCapture {
            sessionQueue.async {
                self.applyActiveFormat(forRecording: false)
            }
        }
        sessionQueue.async {
            self.activePhotoProcessors.removeValue(forKey: photoSettingsID)
        }

        guard let image else {
            Task { @MainActor in
                self.isCapturingPhoto = false
                self.notice = errorMessage ?? "Photo capture failed"
            }
            completion?()
            return
        }

        let aspected = applyPhotoAspect(image, square: request.square)
        let needsReencode = request.square || request.jpeg
        savePhoto(aspected,
                  originalData: needsReencode ? nil : originalData,
                  metadata: metadata,
                  to: request.destination,
                  jpeg: request.jpeg,
                  isBurstFrame: request.isBurstFrame,
                  completion: completion)
    }

    func savePhoto(_ image: UIImage,
                    originalData: Data? = nil,
                    metadata: [String: Any]?,
                    to destination: SaveLocation,
                    jpeg: Bool,
                    isBurstFrame: Bool = false,
                    completion: (() -> Void)? = nil) {
        let wantsJPEG = jpeg
        let heicData = wantsJPEG ? nil : (originalData ?? PhotoEncoder.encodeHEIC(image, metadata: metadata))
        let data = heicData ?? PhotoEncoder.encodeJPEG(image, metadata: metadata)
        guard let data else {
            Task { @MainActor in
                self.notice = "Photo encoding failed"
                self.isCapturingPhoto = false
                completion?()
            }
            return
        }
        let isHEIC = heicData != nil
        let name = CaptureFileNamer.nextFileName(extension: isHEIC ? "heic" : "jpg")
        let thumbnail = PhotoPersistence.thumbnail(image)
        PhotoPersistence.save(data: data, name: name, destination: destination) { url, assetID, error in
            Task { @MainActor in
                self.isCapturingPhoto = false
                self.notice = error
                if let url {
                    self.lastPhotoThumbnail = thumbnail
                    self.lastClipThumbnail = nil
                    let item = PhotoReviewItem(image: thumbnail, url: url, assetIdentifier: assetID)
                    if isBurstFrame {
                        self.lastBurstReviewItems.append(item)
                    } else {
                        self.lastPhotoReviewItem = item
                        self.photoReviewToken += 1
                    }
                    self.refreshFreeSpace()
                }
                completion?()
            }
        }
    }

    /// Standard QuickTime metadata (make, model, software, creation date) so
    /// recorded clips show device info in the Photos app's "ⓘ" panel, the
    /// same fields the stock Camera app writes.
    static func captureMetadataItems() -> [AVMetadataItem] {
        var items: [AVMetadataItem] = []

        func item(_ identifier: AVMetadataIdentifier, _ value: String) -> AVMetadataItem {
            let m = AVMutableMetadataItem()
            m.identifier = identifier
            m.value = value as NSString
            m.dataType = kCMMetadataBaseDataType_UTF8 as String
            return m
        }

        items.append(item(.quickTimeMetadataMake, "Apple"))
        items.append(item(.quickTimeMetadataModel, UIDevice.current.modelIdentifier))
        items.append(item(.quickTimeMetadataSoftware, "LowPolyCam"))

        let iso8601 = ISO8601DateFormatter()
        items.append(item(.quickTimeMetadataCreationDate, iso8601.string(from: Date())))

        return items
    }


}
