import AVFoundation
import SwiftUI
import UIKit

struct CameraPreview: UIViewRepresentable {
    @Environment(\.cameraTint) private var theme
    let session: AVCaptureSession
    let isFocusExposureLocked: Bool
    let stabilizationEnabled: Bool
    let isPreviewTransitioning: Bool
    var fitsPhoto = false
    let onTapToFocus: (CGPoint) -> Void
    let onLongPressToLock: (CGPoint) -> Void

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        configure(view)
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        if uiView.previewLayer.session !== session { uiView.previewLayer.session = session }
        configure(uiView)
        guard !isPreviewTransitioning else { return }
        uiView.updateRotation()
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
    private var transitionSnapshot: UIView?
    private var previewTransitioning = false
    // Type-erased storage allows the view itself to remain available on iOS 15/16.
    private var rotationCoordinator: AnyObject?
    private var rotationObservation: NSKeyValueObservation?
    private var orientationObserver: NSObjectProtocol?
    private var rotationDeviceID: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        previewLayer.videoGravity = .resizeAspectFill
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
        transitionSnapshot?.frame = bounds

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
        guard #available(iOS 17.0, *) else {
            guard connection.isVideoOrientationSupported,
                  let orientation = window?.windowScene?.interfaceOrientation else { return }
            let videoOrientation: AVCaptureVideoOrientation
            switch orientation {
            case .portrait: videoOrientation = .portrait
            case .portraitUpsideDown: videoOrientation = .portraitUpsideDown
            case .landscapeLeft: videoOrientation = .landscapeLeft
            case .landscapeRight: videoOrientation = .landscapeRight
            default: return
            }
            if connection.videoOrientation != videoOrientation {
                connection.videoOrientation = videoOrientation
            }
            return
        }

        guard let input = previewLayer.session?.inputs.compactMap({ $0 as? AVCaptureDeviceInput }).first(where: {
            $0.ports.contains(where: { $0.mediaType == .video })
        }) else { return }

        if rotationDeviceID != input.device.uniqueID {
            rotationObservation?.invalidate()
            rotationDeviceID = input.device.uniqueID
            let coordinator = AVCaptureDevice.RotationCoordinator(device: input.device, previewLayer: previewLayer)
            rotationCoordinator = coordinator
            // Rotation changes must update the preview even while the camera is idle and no
            // SwiftUI state happens to be publishing. Discard notifications from an old lens.
            rotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.new]) { [weak self] coordinator, _ in
                DispatchQueue.main.async { [weak self, weak coordinator] in
                    guard let self, let coordinator, self.rotationCoordinator === coordinator,
                          !self.previewTransitioning else { return }
                    self.applyPreviewRotation(coordinator.videoRotationAngleForHorizonLevelPreview)
                }
            }
        }

        if let coordinator = rotationCoordinator as? AVCaptureDevice.RotationCoordinator {
            applyPreviewRotation(coordinator.videoRotationAngleForHorizonLevelPreview)
        }
    }

    @available(iOS 17.0, *)
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
            transitionSnapshot?.removeFromSuperview()
            transitionSnapshot = nil
            guard bounds.width > 0, bounds.height > 0,
                  let snapshot = snapshotView(afterScreenUpdates: false) else { return }
            snapshot.frame = bounds
            snapshot.isUserInteractionEnabled = false
            addSubview(snapshot)
            transitionSnapshot = snapshot
        } else if let snapshot = transitionSnapshot {
            UIView.animate(withDuration: 0.14, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
                snapshot.alpha = 0
            } completion: { [weak self, weak snapshot] _ in
                snapshot?.removeFromSuperview()
                if self?.transitionSnapshot === snapshot {
                    self?.transitionSnapshot = nil
                }
            }
        }
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
