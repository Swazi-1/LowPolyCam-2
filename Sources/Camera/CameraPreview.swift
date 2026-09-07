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
    private let transitionBlurView = UIVisualEffectView(effect: nil)
    private let transitionToneView = UIView()
    private var transitionAnimator: UIViewPropertyAnimator?
    private var transitionReadinessWorkItem: DispatchWorkItem?
    private var activeTransitionRequest: PreviewTransitionRequest?
    private var transitionVisibleAt: CFTimeInterval?
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
        transitionBlurView.isUserInteractionEnabled = false
        transitionBlurView.isHidden = true
        transitionBlurView.alpha = 1
        transitionToneView.isUserInteractionEnabled = false
        transitionToneView.backgroundColor = UIColor.black.withAlphaComponent(0.14)
        transitionToneView.alpha = 0
        transitionBlurView.contentView.addSubview(transitionToneView)
        addSubview(transitionBlurView)
    }

    private func showTransitionCoverIfNeeded() {
        transitionAnimator?.stopAnimation(true)
        transitionBlurView.isHidden = false
        transitionBlurView.alpha = 1
        if transitionVisibleAt == nil { transitionVisibleAt = CACurrentMediaTime() }

        if UIAccessibility.isReduceMotionEnabled {
            transitionBlurView.effect = nil
            UIView.animate(withDuration: 0.06, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
                self.transitionToneView.alpha = 1
            }
            return
        }

        let animator = UIViewPropertyAnimator(duration: 0.08, curve: .easeOut) {
            self.transitionBlurView.effect = UIBlurEffect(style: .systemChromeMaterialDark)
            self.transitionToneView.alpha = 0.72
        }
        transitionAnimator = animator
        animator.startAnimation()
    }

    private func hideTransitionCover() {
        transitionReadinessWorkItem?.cancel()
        transitionReadinessWorkItem = nil
        let elapsed = transitionVisibleAt.map { CACurrentMediaTime() - $0 } ?? 0
        let delay = max(0, 0.12 - elapsed)
        transitionAnimator?.stopAnimation(false)

        if UIAccessibility.isReduceMotionEnabled {
            UIView.animate(withDuration: 0.08, delay: delay, options: [.beginFromCurrentState, .allowUserInteraction]) {
                self.transitionToneView.alpha = 0
            } completion: { _ in
                guard self.activeTransitionRequest == nil, !self.legacyCoverVisible else { return }
                self.transitionBlurView.isHidden = true
                self.transitionVisibleAt = nil
            }
            return
        }

        let animator = UIViewPropertyAnimator(duration: 0.14, curve: .easeOut) {
            self.transitionBlurView.effect = nil
            self.transitionToneView.alpha = 0
        }
        transitionAnimator = animator
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak animator] in
            guard let self, let animator,
                  self.activeTransitionRequest == nil, !self.legacyCoverVisible else { return }
            animator.addCompletion { [weak self] _ in
                guard let self, self.activeTransitionRequest == nil, !self.legacyCoverVisible else { return }
                self.transitionBlurView.isHidden = true
                self.transitionVisibleAt = nil
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
        showTransitionCoverIfNeeded()

        // Do not wait for the full blur animation. Give the cover one display opportunity,
        // then let the serial camera queue perform the hardware transaction.
        DispatchQueue.main.asyncAfter(deadline: .now() + (1.0 / 60.0)) { [weak self] in
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
