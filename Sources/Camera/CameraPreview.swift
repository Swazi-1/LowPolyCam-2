import AVFoundation
import SwiftUI
import UIKit

struct CameraPreview: UIViewRepresentable {
    @Environment(\.cameraTint) private var theme
    let session: AVCaptureSession
    let isFocusExposureLocked: Bool
    let stabilizationEnabled: Bool
    let isPreviewTransitioning: Bool
    let transitionController: PreviewTransitionController
    var fitsPhoto = false
    let onTapToFocus: (CGPoint) -> Void
    let onLongPressToLock: (CGPoint) -> Void

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        transitionController.attach(view)
        view.transitionController = transitionController
        configure(view)
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        if uiView.previewLayer.session !== session { uiView.previewLayer.session = session }
        if uiView.transitionController !== transitionController {
            uiView.transitionController?.detach(uiView)
            transitionController.attach(uiView)
            uiView.transitionController = transitionController
        }
        configure(uiView)
        guard !isPreviewTransitioning else { return }
        uiView.updateRotation()
    }

    static func dismantleUIView(_ uiView: PreviewView, coordinator: ()) {
        uiView.transitionController?.detach(uiView)
        uiView.transitionController = nil
    }

    private func configure(_ view: PreviewView) {
        view.setPreviewTransitioning(isPreviewTransitioning)
        guard !isPreviewTransitioning else { return }
        let gravity: AVLayerVideoGravity = fitsPhoto ? .resizeAspect : .resizeAspectFill
        if view.previewLayer.videoGravity != gravity { view.previewLayer.videoGravity = gravity }
        view.tintColor = UIColor(theme)
        view.onTapToFocus = onTapToFocus
        view.onLongPressToLock = onLongPressToLock
        view.setFocusExposureLocked(isFocusExposureLocked)
        view.setStabilizationEnabled(stabilizationEnabled)
    }
}

final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

    var onTapToFocus: ((CGPoint) -> Void)?
    var onLongPressToLock: ((CGPoint) -> Void)?

    private let focusIndicator = UIView()
    private let lockLabel = UILabel()
    private var hideFocusWorkItem: DispatchWorkItem?
    private var focusExposureLocked = false
    private var stabilizationEnabled = true
    weak var transitionController: PreviewTransitionController?
    private enum TransitionCoverStyle {
        case neutral
        case scenePreservingOptical
    }

    private struct TransitionSceneSample {
        let image: UIImage
        let color: UIColor
    }

    private let transitionSceneImageView = UIImageView()
    private let transitionBlurView = UIVisualEffectView(effect: nil)
    private let transitionToneView = UIView()
    private let neutralTransitionEffect = UIBlurEffect(style: .systemChromeMaterialDark)
    private let opticalTransitionEffect = UIBlurEffect(style: .prominent)
    private let transitionSceneRenderer: UIGraphicsImageRenderer = {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: 12, height: 20), format: format)
    }()
    private var transitionAnimator: UIViewPropertyAnimator?
    private var transitionReadinessWorkItem: DispatchWorkItem?
    private var activeTransitionRequest: PreviewTransitionRequest?
    private var transitionVisibleAt: CFTimeInterval?
    private var transitionCoverStyle: TransitionCoverStyle = .neutral
    private var transitionSceneColor: UIColor?
    private var legacyCoverVisible = false
    private var previewTransitioning = false
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?
    private var orientationObserver: NSObjectProtocol?
    private var rotationDeviceID: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        previewLayer.videoGravity = .resizeAspectFill
        configureTransitionCover()
        configureOverlays()
        configureGestures()
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        orientationObserver = NotificationCenter.default.addObserver(
            forName: UIDevice.orientationDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.updateRotation()
        }
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        hideFocusWorkItem?.cancel()
        transitionReadinessWorkItem?.cancel()
        transitionAnimator?.stopAnimation(true)
        rotationObservation?.invalidate()
        if let orientationObserver { NotificationCenter.default.removeObserver(orientationObserver) }
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
    }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        focusIndicator.layer.borderColor = tintColor.cgColor
        lockLabel.textColor = tintColor
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if !previewTransitioning {
            enableStabilizationIfAvailable()
            updateRotation()
        }
        transitionSceneImageView.frame = bounds
        transitionBlurView.frame = bounds
        transitionToneView.frame = transitionBlurView.bounds

        lockLabel.sizeToFit()
        lockLabel.frame = CGRect(
            x: (bounds.width - lockLabel.bounds.width - 24) / 2,
            y: max(safeAreaInsets.top + 54, 70),
            width: lockLabel.bounds.width + 24,
            height: 30
        )
    }

    func updateRotation() {
        guard !previewTransitioning else { return }
        guard let connection = previewLayer.connection else { return }
        guard let input = previewLayer.session?.inputs.compactMap({ $0 as? AVCaptureDeviceInput }).first(where: {
            $0.ports.contains(where: { $0.mediaType == .video })
        }) else { return }

        if rotationDeviceID != input.device.uniqueID {
            rotationObservation?.invalidate()
            rotationDeviceID = input.device.uniqueID
            let coordinator = AVCaptureDevice.RotationCoordinator(device: input.device, previewLayer: previewLayer)
            rotationCoordinator = coordinator
            rotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.new]) { [weak self, weak coordinator] _, _ in
                DispatchQueue.main.async {
                    guard let self, let coordinator, self.rotationCoordinator === coordinator,
                          !self.previewTransitioning else { return }
                    self.applyPreviewRotation(coordinator.videoRotationAngleForHorizonLevelPreview)
                }
            }
        }

        if let coordinator = rotationCoordinator {
            applyPreviewRotation(coordinator.videoRotationAngleForHorizonLevelPreview)
        }
    }

    private func applyPreviewRotation(_ angle: CGFloat) {
        guard let connection = previewLayer.connection,
              connection.isVideoRotationAngleSupported(angle) else { return }
        if abs(connection.videoRotationAngle - angle) > 0.01 {
            connection.videoRotationAngle = angle
        }
    }

    func enableStabilizationIfAvailable() {
        guard let connection = previewLayer.connection, connection.isVideoStabilizationSupported else { return }
        let mode: AVCaptureVideoStabilizationMode = stabilizationEnabled ? .auto : .off
        if connection.preferredVideoStabilizationMode != mode {
            connection.preferredVideoStabilizationMode = mode
        }
    }

    func setStabilizationEnabled(_ enabled: Bool) {
        stabilizationEnabled = enabled
        enableStabilizationIfAvailable()
    }

    func setPreviewTransitioning(_ transitioning: Bool) {
        guard transitioning != previewTransitioning else { return }
        previewTransitioning = transitioning

        if transitioning {
            if activeTransitionRequest == nil {
                legacyCoverVisible = true
                showTransitionCoverIfNeeded()
            }
        } else {
            // A broad camera-flip lock can hand ownership of the same visual cover to an
            // identity-based transition. Clear the legacy owner even while that transition is
            // active so its eventual readiness completion is allowed to dissolve the cover.
            legacyCoverVisible = false
            if activeTransitionRequest == nil {
                hideTransitionCover()
                updateRotation()
            }
        }
    }

    private func configureTransitionCover() {
        transitionSceneImageView.isUserInteractionEnabled = false
        transitionSceneImageView.isHidden = true
        transitionSceneImageView.alpha = 0
        transitionSceneImageView.contentMode = .scaleAspectFill
        transitionSceneImageView.clipsToBounds = true
        transitionSceneImageView.layer.magnificationFilter = .linear
        transitionSceneImageView.layer.minificationFilter = .linear
        addSubview(transitionSceneImageView)

        transitionBlurView.isUserInteractionEnabled = false
        transitionBlurView.isHidden = true
        transitionBlurView.alpha = 1
        transitionToneView.isUserInteractionEnabled = false
        transitionToneView.backgroundColor = .clear
        transitionToneView.alpha = 0
        transitionBlurView.contentView.addSubview(transitionToneView)
        addSubview(transitionBlurView)
    }

    /// Builds the optical handoff cover from the outgoing preview instead of forcing a black
    /// material. A tiny downsample is enough: the goal is the scene's overall light/color, not
    /// a frame capture. If AVFoundation's preview surface cannot be represented by drawHierarchy
    /// on a device, the sampler rejects a near-empty black result and the live neutral blur is
    /// used by itself rather than introducing a fake black flash.
    private func sampleOutgoingScene() -> TransitionSceneSample? {
        guard bounds.width > 2, bounds.height > 2, transitionBlurView.isHidden else { return nil }

        var hierarchyComplete = false
        let image = transitionSceneRenderer.image { rendererContext in
            let sampleSize = CGSize(width: 12, height: 20)
            rendererContext.cgContext.saveGState()
            rendererContext.cgContext.scaleBy(
                x: sampleSize.width / bounds.width,
                y: sampleSize.height / bounds.height
            )
            hierarchyComplete = drawHierarchy(in: bounds, afterScreenUpdates: false)
            rendererContext.cgContext.restoreGState()
        }
        // UIKit reports false when any part of the hierarchy is missing image data. In that
        // case we deliberately skip the color plate and keep only the live blur.
        guard hierarchyComplete, let cgImage = image.cgImage else { return nil }

        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        let didRender = pixels.withUnsafeMutableBytes { rawBuffer -> Bool in
            guard let baseAddress = rawBuffer.baseAddress,
                  let context = CGContext(
                    data: baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width * 4,
                    space: colorSpace,
                    bitmapInfo: bitmapInfo
                  ) else { return false }
            context.interpolationQuality = .low
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard didRender else { return nil }

        // Ignore the outer rows so Photo's aspect-fit letterbox bars do not darken the scene
        // color. The center also avoids most focus/UI decoration inside PreviewView.
        let minX = max(0, width / 12)
        let maxX = min(width, width - minX)
        let minY = max(0, height / 5)
        let maxY = min(height, height - minY)
        var red = 0.0
        var green = 0.0
        var blue = 0.0
        var weight = 0.0
        for y in minY..<maxY {
            for x in minX..<maxX {
                let offset = (y * width + x) * 4
                let alpha = Double(pixels[offset + 3]) / 255.0
                guard alpha > 0.5 else { continue }
                red += Double(pixels[offset]) * alpha
                green += Double(pixels[offset + 1]) * alpha
                blue += Double(pixels[offset + 2]) * alpha
                weight += alpha
            }
        }
        guard weight > 1 else { return nil }
        red /= 255.0 * weight
        green /= 255.0 * weight
        blue /= 255.0 * weight

        let maximum = max(red, max(green, blue))
        let minimum = min(red, min(green, blue))
        let luma = 0.2126 * red + 0.7152 * green + 0.0722 * blue
        // A uniform near-black hierarchy image is a common failure mode when a hardware-backed
        // preview surface cannot be snapshotted. Do not let that failure become a black cover.
        guard luma > 0.018 || maximum - minimum > 0.018 else { return nil }
        let color = UIColor(red: CGFloat(red), green: CGFloat(green), blue: CGFloat(blue), alpha: 1)
        return TransitionSceneSample(image: image, color: color)
    }

    @discardableResult
    private func showTransitionCoverIfNeeded(for request: PreviewTransitionRequest? = nil) -> Bool {
        let requestedStyle: TransitionCoverStyle = request?.usesScenePreservingOpticalBlend == true
            ? .scenePreservingOptical
            : .neutral
        let newlyVisible = transitionBlurView.isHidden || transitionVisibleAt == nil
        // Sample before un-hiding the effect view; otherwise the sampler would read our own
        // cover instead of the outgoing camera preview.
        let sampledScene = newlyVisible && requestedStyle == .scenePreservingOptical
            ? sampleOutgoingScene()
            : nil

        transitionAnimator?.stopAnimation(true)
        transitionBlurView.isHidden = false
        transitionBlurView.alpha = 1
        if newlyVisible {
            transitionVisibleAt = CACurrentMediaTime()
            transitionCoverStyle = requestedStyle
            transitionSceneColor = sampledScene?.color
            transitionSceneImageView.image = sampledScene?.image
        }
        if transitionCoverStyle == .scenePreservingOptical, transitionSceneImageView.image != nil {
            transitionSceneImageView.isHidden = false
            transitionSceneImageView.alpha = 1
        } else if transitionCoverStyle == .neutral {
            transitionSceneImageView.isHidden = true
            transitionSceneImageView.alpha = 0
        }

        switch transitionCoverStyle {
        case .scenePreservingOptical:
            transitionToneView.backgroundColor = transitionSceneColor ?? .clear
            if UIAccessibility.isReduceMotionEnabled {
                transitionBlurView.effect = nil
                UIView.animate(
                    withDuration: newlyVisible ? 0.06 : 0.03,
                    delay: 0,
                    options: [.beginFromCurrentState, .allowUserInteraction]
                ) {
                    self.transitionToneView.alpha = self.transitionSceneColor == nil ? 0 : 0.22
                }
                return newlyVisible
            }

            // Match the visual behavior seen in iOS Camera: collapse the outgoing scene into a
            // strongly blurred, scene-colored field. The sensor transaction starts after the
            // cover has had a couple of display opportunities, not after a long fixed animation.
            let animator = UIViewPropertyAnimator(duration: newlyVisible ? 0.075 : 0.035, curve: .easeOut) {
                self.transitionBlurView.effect = self.opticalTransitionEffect
                self.transitionToneView.alpha = self.transitionSceneColor == nil ? 0.08 : 0.20
            }
            transitionAnimator = animator
            animator.startAnimation()

        case .neutral:
            transitionToneView.backgroundColor = UIColor.black.withAlphaComponent(0.14)
            if UIAccessibility.isReduceMotionEnabled {
                transitionBlurView.effect = nil
                UIView.animate(withDuration: 0.06, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
                    self.transitionToneView.alpha = 1
                }
                return newlyVisible
            }

            let animator = UIViewPropertyAnimator(duration: 0.08, curve: .easeOut) {
                self.transitionBlurView.effect = self.neutralTransitionEffect
                self.transitionToneView.alpha = 0.72
            }
            transitionAnimator = animator
            animator.startAnimation()
        }
        return newlyVisible
    }

    private func hideTransitionCover() {
        transitionReadinessWorkItem?.cancel()
        transitionReadinessWorkItem = nil
        let style = transitionCoverStyle
        let elapsed = transitionVisibleAt.map { CACurrentMediaTime() - $0 } ?? 0
        // Do not add a fixed sensor delay. This is only a tiny visual floor so a fast handoff
        // cannot flash a one-frame cover. Real 4K60/HFR handoffs remain readiness-driven.
        let minimumVisible = style == .scenePreservingOptical ? 0.11 : 0.12
        let delay = max(0, minimumVisible - elapsed)
        transitionAnimator?.stopAnimation(false)

        let cleanup: () -> Void = { [weak self] in
            guard let self, self.activeTransitionRequest == nil, !self.legacyCoverVisible else { return }
            self.transitionBlurView.isHidden = true
            self.transitionVisibleAt = nil
            self.transitionSceneColor = nil
            self.transitionSceneImageView.image = nil
            self.transitionSceneImageView.alpha = 0
            self.transitionSceneImageView.isHidden = true
            self.transitionCoverStyle = .neutral
            self.transitionToneView.backgroundColor = .clear
        }

        if UIAccessibility.isReduceMotionEnabled {
            UIView.animate(
                withDuration: style == .scenePreservingOptical ? 0.10 : 0.08,
                delay: delay,
                options: [.beginFromCurrentState, .allowUserInteraction]
            ) {
                self.transitionToneView.alpha = 0
                if style == .scenePreservingOptical { self.transitionSceneImageView.alpha = 0 }
            } completion: { _ in
                cleanup()
            }
            return
        }

        // The incoming sensor appears under the same blur first, then sharpens. This avoids the
        // old dark-cover -> sudden-clear-preview look and mirrors the iOS Camera clip much more
        // closely without encoding any effect into captured media.
        let animator = UIViewPropertyAnimator(
            duration: style == .scenePreservingOptical ? 0.17 : 0.14,
            curve: .easeOut
        ) {
            self.transitionBlurView.effect = nil
            self.transitionToneView.alpha = 0
            if style == .scenePreservingOptical { self.transitionSceneImageView.alpha = 0 }
        }
        transitionAnimator = animator
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak animator] in
            guard let self, let animator,
                  self.activeTransitionRequest == nil, !self.legacyCoverVisible else { return }
            animator.addCompletion { [weak self] _ in
                guard let self else { return }
                cleanup()
            }
            animator.startAnimation()
        }
    }

    private func schedulePreviewReadiness(for request: PreviewTransitionRequest, attempt: Int = 0) {
        transitionReadinessWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.activeTransitionRequest?.id == request.id,
                  let targetDeviceID = request.targetDeviceID else { return }
            let activeDeviceID = self.previewLayer.session?.inputs
                .compactMap { $0 as? AVCaptureDeviceInput }
                .first(where: { $0.ports.contains(where: { $0.mediaType == .video }) })?
                .device.uniqueID

            guard self.previewLayer.isPreviewing, activeDeviceID == targetDeviceID else {
                if attempt < 12 { self.schedulePreviewReadiness(for: request, attempt: attempt + 1) }
                return
            }

            // Public AVFoundation does not expose an exact "first frame from this new lens" callback.
            // Require the target input identity + active preview state, then give Core Animation two
            // display opportunities before dissolving the cover. The controller watchdog handles stalls.
            DispatchQueue.main.asyncAfter(deadline: .now() + (1.0 / 60.0)) { [weak self] in
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.activeTransitionRequest?.id == request.id else { return }
                    let confirmedDeviceID = self.previewLayer.session?.inputs
                        .compactMap { $0 as? AVCaptureDeviceInput }
                        .first(where: { $0.ports.contains(where: { $0.mediaType == .video }) })?
                        .device.uniqueID
                    guard self.previewLayer.isPreviewing, confirmedDeviceID == targetDeviceID else {
                        self.schedulePreviewReadiness(for: request, attempt: attempt + 1)
                        return
                    }
                    self.transitionController?.reportPreviewResumed(id: request.id, deviceID: targetDeviceID)
                }
            }
        }
        transitionReadinessWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (attempt == 0 ? 0 : 0.016), execute: work)
    }

    func setFocusExposureLocked(_ isLocked: Bool) {
        let wasLocked = focusExposureLocked
        focusExposureLocked = isLocked
        lockLabel.isHidden = !isLocked
        focusIndicator.layer.borderColor = tintColor.cgColor
        if isLocked {
            hideFocusWorkItem?.cancel()
        } else if wasLocked {
            // Keep a freshly tapped focus box visible; its own timer fades it naturally.
        }
    }

    private func configureOverlays() {
        focusIndicator.isUserInteractionEnabled = false
        focusIndicator.layer.borderWidth = 2
        focusIndicator.layer.borderColor = tintColor.cgColor
        focusIndicator.layer.cornerRadius = 7
        focusIndicator.alpha = 0
        addSubview(focusIndicator)

        lockLabel.isUserInteractionEnabled = false
        lockLabel.text = "AE/AF LOCK"
        lockLabel.textAlignment = .center
        lockLabel.font = .systemFont(ofSize: 13, weight: .bold)
        lockLabel.textColor = tintColor
        lockLabel.backgroundColor = UIColor.black.withAlphaComponent(0.52)
        lockLabel.layer.cornerRadius = 15
        lockLabel.clipsToBounds = true
        lockLabel.isHidden = true
        addSubview(lockLabel)
    }

    private func configureGestures() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        addGestureRecognizer(tap)

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = 0.55
        longPress.allowableMovement = 18
        addGestureRecognizer(longPress)

        tap.require(toFail: longPress)
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended, !previewTransitioning else { return }
        let layerPoint = recognizer.location(in: self)
        guard isInsideCameraImage(layerPoint) else { return }
        showFocusIndicator(at: layerPoint, locked: false)
        let devicePoint = previewLayer.captureDevicePointConverted(fromLayerPoint: layerPoint)
        onTapToFocus?(devicePoint)
    }

    @objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began, !previewTransitioning else { return }
        let layerPoint = recognizer.location(in: self)
        guard isInsideCameraImage(layerPoint) else { return }
        showFocusIndicator(at: layerPoint, locked: true)
        let devicePoint = previewLayer.captureDevicePointConverted(fromLayerPoint: layerPoint)
        onLongPressToLock?(devicePoint)
    }

    private func isInsideCameraImage(_ point: CGPoint) -> Bool {
        // Photo previews use aspect-fit. A tap in a letterbox bar isn't a focus target.
        guard previewLayer.videoGravity == .resizeAspect else { return true }
        let imageRect = previewLayer.layerRectConverted(fromMetadataOutputRect: CGRect(x: 0, y: 0, width: 1, height: 1))
        return imageRect.contains(point)
    }

    private func showFocusIndicator(at point: CGPoint, locked: Bool) {
        hideFocusWorkItem?.cancel()
        let side: CGFloat = 72
        focusIndicator.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        focusIndicator.center = CGPoint(
            x: min(max(point.x, side / 2), bounds.width - side / 2),
            y: min(max(point.y, side / 2), bounds.height - side / 2)
        )
        focusIndicator.transform = CGAffineTransform(scaleX: 1.22, y: 1.22)
        focusIndicator.alpha = 1
        // The lock pill reflects the hardware lock state published by CameraManager.
        // A long press only shows the focus box until AF/AE has actually settled and locked.
        if !locked {
            lockLabel.isHidden = true
        }

        UIView.animate(withDuration: 0.18) {
            self.focusIndicator.transform = .identity
        }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self, !self.focusExposureLocked else { return }
            UIView.animate(withDuration: 0.22) {
                self.focusIndicator.alpha = 0
            }
        }
        hideFocusWorkItem = workItem
        // Leave enough time for an AF/AE lock request to settle; a rejected or unsupported
        // lock still fades instead of leaving the focus box permanently on screen.
        DispatchQueue.main.asyncAfter(deadline: .now() + (locked ? 3.0 : 1.15), execute: workItem)
    }
}


extension PreviewView: PreviewTransitionPresenting {
    func preparePreviewTransition(_ request: PreviewTransitionRequest, covered: @escaping (UInt64) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        transitionReadinessWorkItem?.cancel()
        activeTransitionRequest = request
        let newlyVisible = showTransitionCoverIfNeeded(for: request)

        // For a fresh optical handoff, give the scene-colored blur two 60 Hz display
        // opportunities before touching the capture topology. Reverse requests already under
        // cover acknowledge immediately, so held zoom never accumulates artificial latency.
        let acknowledgementDelay: TimeInterval
        if !newlyVisible {
            acknowledgementDelay = 0
        } else if request.usesScenePreservingOpticalBlend {
            acknowledgementDelay = 2.0 / 60.0
        } else {
            acknowledgementDelay = 1.0 / 60.0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + acknowledgementDelay) { [weak self] in
            guard let self, self.activeTransitionRequest?.id == request.id else { return }
            covered(request.id)
        }
    }

    func commitPreviewTransition(_ request: PreviewTransitionRequest) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard activeTransitionRequest?.id == request.id else { return }
        updateRotation()
        schedulePreviewReadiness(for: request)
    }

    func finishPreviewTransition(id: UInt64) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard activeTransitionRequest?.id == id else { return }
        activeTransitionRequest = nil
        if !legacyCoverVisible { hideTransitionCover() }
        if !previewTransitioning { updateRotation() }
    }

    func cancelPreviewTransition(id: UInt64, keepCoverForReplacement: Bool) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard activeTransitionRequest?.id == id else { return }
        transitionReadinessWorkItem?.cancel()
        transitionReadinessWorkItem = nil
        activeTransitionRequest = nil
        if !keepCoverForReplacement, !legacyCoverVisible {
            hideTransitionCover()
        }
        if !previewTransitioning { updateRotation() }
    }
}
