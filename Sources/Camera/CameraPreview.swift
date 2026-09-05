import AVFoundation
import SwiftUI
import UIKit

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let isFocusExposureLocked: Bool
    let exposureBias: Float
    let onTapToFocus: (CGPoint) -> Void
    let onLongPressToLock: (CGPoint) -> Void
    let onExposureDragBegan: () -> Void
    let onExposureDragChanged: (Float) -> Void

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        configure(view)
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.previewLayer.session = session
        configure(uiView)
        uiView.enableStabilizationIfAvailable()
    }

    private func configure(_ view: PreviewView) {
        view.onTapToFocus = onTapToFocus
        view.onLongPressToLock = onLongPressToLock
        view.onExposureDragBegan = onExposureDragBegan
        view.onExposureDragChanged = onExposureDragChanged
        view.setFocusExposureLocked(isFocusExposureLocked)
        view.setExposureBias(exposureBias)
    }
}

final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

    var onTapToFocus: ((CGPoint) -> Void)?
    var onLongPressToLock: ((CGPoint) -> Void)?
    var onExposureDragBegan: (() -> Void)?
    var onExposureDragChanged: ((Float) -> Void)?

    private let focusIndicator = UIView()
    private let lockLabel = UILabel()
    private let exposureContainer = UIView()
    private let exposureIcon = UIImageView(image: UIImage(systemName: "sun.max.fill"))
    private let exposureLabel = UILabel()
    private var hideFocusWorkItem: DispatchWorkItem?
    private var hideExposureWorkItem: DispatchWorkItem?
    private var focusExposureLocked = false

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

        lockLabel.sizeToFit()
        lockLabel.frame = CGRect(
            x: (bounds.width - lockLabel.bounds.width - 24) / 2,
            y: max(safeAreaInsets.top + 54, 70),
            width: lockLabel.bounds.width + 24,
            height: 30
        )

        exposureContainer.frame = CGRect(
            x: bounds.width - 82,
            y: (bounds.height - 108) / 2,
            width: 58,
            height: 108
        )
        exposureIcon.frame = CGRect(x: 17, y: 14, width: 24, height: 24)
        exposureLabel.frame = CGRect(x: 4, y: 48, width: 50, height: 42)
    }

    func enableStabilizationIfAvailable() {
        guard let connection = previewLayer.connection, connection.isVideoStabilizationSupported else { return }
        connection.preferredVideoStabilizationMode = .auto
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

    func setExposureBias(_ bias: Float) {
        if abs(bias) < 0.05 {
            exposureLabel.text = "0.0\nEV"
        } else {
            exposureLabel.text = String(format: "%+.1f\nEV", bias)
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

        exposureContainer.isUserInteractionEnabled = false
        exposureContainer.backgroundColor = UIColor.black.withAlphaComponent(0.48)
        exposureContainer.layer.cornerRadius = 18
        exposureContainer.alpha = 0
        addSubview(exposureContainer)

        exposureIcon.tintColor = .systemYellow
        exposureIcon.contentMode = .scaleAspectFit
        exposureContainer.addSubview(exposureIcon)

        exposureLabel.textAlignment = .center
        exposureLabel.numberOfLines = 2
        exposureLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        exposureLabel.textColor = .white
        exposureContainer.addSubview(exposureLabel)
    }

    private func configureGestures() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        addGestureRecognizer(tap)

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = 0.55
        longPress.allowableMovement = 18
        addGestureRecognizer(longPress)

        tap.require(toFail: longPress)

        let exposurePan = UIPanGestureRecognizer(target: self, action: #selector(handleExposurePan(_:)))
        exposurePan.maximumNumberOfTouches = 1
        addGestureRecognizer(exposurePan)
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

    @objc private func handleExposurePan(_ recognizer: UIPanGestureRecognizer) {
        switch recognizer.state {
        case .began:
            hideExposureWorkItem?.cancel()
            exposureContainer.alpha = 1
            onExposureDragBegan?()
        case .changed:
            let translation = recognizer.translation(in: self)
            let deltaEV = Float(-translation.y / 120)
            onExposureDragChanged?(deltaEV)
        case .ended, .cancelled, .failed:
            scheduleExposureIndicatorHide()
        default:
            break
        }
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

    private func scheduleExposureIndicatorHide() {
        hideExposureWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            UIView.animate(withDuration: 0.2) {
                self?.exposureContainer.alpha = 0
            }
        }
        hideExposureWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: workItem)
    }
}
