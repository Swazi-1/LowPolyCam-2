import Foundation

enum ZoomRoutingPolicy {
    /// Select the longest optical lens that can show the requested field of view. When
    /// dragging back across a boundary, a small dead band prevents input-swap chatter.
    static func opticalBase(
        for zoom: CGFloat,
        availableBases: [CGFloat],
        currentBase: CGFloat? = nil,
        interactive: Bool = false
    ) -> CGFloat? {
        let bases = availableBases.filter { $0.isFinite && $0 > 0 }.sorted()
        guard zoom.isFinite, let first = bases.first else { return nil }
        if interactive, let currentBase, bases.contains(currentBase),
           zoom < currentBase, zoom >= currentBase * 0.96 {
            return currentBase
        }
        return bases.last(where: { $0 <= zoom }) ?? first
    }

    static func clamp(_ zoom: CGFloat, to domain: ClosedRange<CGFloat>) -> CGFloat {
        guard zoom.isFinite else { return domain.lowerBound }
        return min(max(zoom, domain.lowerBound), domain.upperBound)
    }

    static func settledZoom(_ zoom: CGFloat, in domain: ClosedRange<CGFloat>) -> CGFloat {
        let clamped = clamp(zoom, to: domain)
        if domain.contains(0.5), abs(clamped - 0.5) < 0.10 { return 0.5 }
        if domain.contains(1), abs(clamped - 1) < 0.16 { return 1 }
        return clamped
    }
}
