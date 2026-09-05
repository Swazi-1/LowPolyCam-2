import AVFoundation
import SwiftUI
import UIKit

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let isFocusExposureLocked: Bool
    let stabilizationEnabled: Bool
    let isPreviewTransitioning: Bool
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
        uiView.enableStabilizationIfAvailable()
    }

    private func configure(_ view: PreviewView) {
        view.onTapToFocus = onTapToFocus
        view.onLongPressToLock = onLongPressToLock
        view.setFocusExposureLocked(isFocusExposureLocked)
        view.setStabilizationEnabled(stabilizationEnabled)
        view.setPreviewTransitioning(isPreviewTransitioning)
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

    override init(frame: CGRect) {
        super.init(frame: frame)
        previewLayer.videoGravity = .resizeAspectFill
        configureOverlays()
        configureGestures()
    }

    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        enableStabilizationIfAvailable()
        transitionSnapshot?.frame = bounds

        lockLabel.sizeToFit()
        lockLabel.frame = CGRect(
            x: (bounds.width - lockLabel.bounds.width - 24) / 2,
            y: max(safeAreaInsets.top + 54, 70),
            width: lockLabel.bounds.width + 24,
            height: 30
        )
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
        focusIndicator.layer.borderColor = UIColor.systemYellow.cgColor
        if isLocked {
            hideFocusWorkItem?.cancel()
        } else if wasLocked {
            UIView.animate(withDuration: 0.2) {
                self.focusIndicator.alpha = 0
            }
        }
    }

    private func configureOverlays() {
        focusIndicator.isUserInteractionEnabled = false
        focusIndicator.layer.borderWidth = 2
        focusIndicator.layer.borderColor = UIColor.systemYellow.cgColor
        focusIndicator.layer.cornerRadius = 7
        focusIndicator.alpha = 0
        addSubview(focusIndicator)

        lockLabel.isUserInteractionEnabled = false
        lockLabel.text = "AE/AF LOCK"
        lockLabel.textAlignment = .center
        lockLabel.font = .systemFont(ofSize: 13, weight: .bold)
        lockLabel.textColor = .systemYellow
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
        guard recognizer.state == .ended else { return }
        let layerPoint = recognizer.location(in: self)
        showFocusIndicator(at: layerPoint, locked: false)
        let devicePoint = previewLayer.captureDevicePointConverted(fromLayerPoint: layerPoint)
        onTapToFocus?(devicePoint)
    }

    @objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began else { return }
        let layerPoint = recognizer.location(in: self)
        showFocusIndicator(at: layerPoint, locked: true)
        let devicePoint = previewLayer.captureDevicePointConverted(fromLayerPoint: layerPoint)
        onLongPressToLock?(devicePoint)
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
        lockLabel.isHidden = !locked

        UIView.animate(withDuration: 0.18) {
            self.focusIndicator.transform = .identity
        }

        guard !locked else { return }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, !self.focusExposureLocked else { return }
            UIView.animate(withDuration: 0.22) {
                self.focusIndicator.alpha = 0
            }
        }
        hideFocusWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.15, execute: workItem)
    }
}
