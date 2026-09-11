import SwiftUI

/// A lightweight composition aid that stays independent from the capture session and output
/// format. It marks an inner safe area without intercepting focus, zoom, or shutter gestures.
struct CameraFrameGuideOverlay: View {
    var body: some View {
        GeometryReader { proxy in
            let horizontalInset = max(22, proxy.size.width * 0.08)
            let verticalInset = max(36, proxy.size.height * 0.08)

            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .stroke(
                    .white.opacity(0.48),
                    style: StrokeStyle(lineWidth: 1, dash: [8, 6], dashPhase: 0)
                )
                .padding(.horizontal, horizontalInset)
                .padding(.vertical, verticalInset)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
