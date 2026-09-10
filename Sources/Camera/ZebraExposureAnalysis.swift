import AVFoundation
import Combine
import CoreMedia
import CoreVideo
import Foundation
import SwiftUI

struct ZebraMask: Equatable {
    let columns: Int
    let rows: Int
    let activeCells: [Bool]

    static let empty = ZebraMask(columns: 24, rows: 16, activeCells: [])

    init(columns: Int, rows: Int, activeCells: [Bool]) {
        self.columns = max(columns, 1)
        self.rows = max(rows, 1)
        self.activeCells = activeCells
    }

    func isActive(column: Int, row: Int) -> Bool {
        guard column >= 0, column < columns, row >= 0, row < rows else { return false }
        let index = row * columns + column
        return index < activeCells.count && activeCells[index]
    }
}

final class ZebraExposureState: ObservableObject {
    @Published private(set) var mask = ZebraMask.empty

    func update(_ next: ZebraMask) {
        if Thread.isMainThread {
            mask = next
        } else {
            DispatchQueue.main.async { [weak self] in self?.mask = next }
        }
    }

    func reset() {
        update(.empty)
    }
}

/// Coarse preview-only highlight detection. It reads the luma plane from the already preview-sized
/// video-data output and never touches the movie-file or photo output buffers.
enum ZebraExposureAnalyzer {
    static func analyze(sampleBuffer: CMSampleBuffer, columns: Int = 24, rows: Int = 16) -> ZebraMask {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return ZebraMask(columns: columns, rows: rows, activeCells: [])
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let width: Int
        let height: Int
        let bytesPerRow: Int
        let baseAddress: UnsafeMutableRawPointer?
        if CVPixelBufferIsPlanar(pixelBuffer), CVPixelBufferGetPlaneCount(pixelBuffer) > 0 {
            width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
            height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
            bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
            baseAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)
        } else {
            width = CVPixelBufferGetWidth(pixelBuffer)
            height = CVPixelBufferGetHeight(pixelBuffer)
            bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
            baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer)
        }
        guard width > 0, height > 0, bytesPerRow > 0, let baseAddress else {
            return ZebraMask(columns: columns, rows: rows, activeCells: [])
        }

        let luma = baseAddress.assumingMemoryBound(to: UInt8.self)
        let safeColumns = max(columns, 1)
        let safeRows = max(rows, 1)
        var active = Array(repeating: false, count: safeColumns * safeRows)
        let threshold = 235
        let samplesPerCell = 6

        for row in 0..<safeRows {
            let yStart = row * height / safeRows
            let yEnd = max(yStart + 1, (row + 1) * height / safeRows)
            for column in 0..<safeColumns {
                let xStart = column * width / safeColumns
                let xEnd = max(xStart + 1, (column + 1) * width / safeColumns)
                var highlightCount = 0
                var sampleCount = 0
                for sampleRow in 0..<samplesPerCell {
                    let y = min(height - 1, yStart + ((sampleRow * 2 + 1) * max(yEnd - yStart, 1)) / (samplesPerCell * 2))
                    for sampleColumn in 0..<samplesPerCell {
                        let x = min(width - 1, xStart + ((sampleColumn * 2 + 1) * max(xEnd - xStart, 1)) / (samplesPerCell * 2))
                        if Int(luma[y * bytesPerRow + x]) >= threshold { highlightCount += 1 }
                        sampleCount += 1
                    }
                }
                active[row * safeColumns + column] = Double(highlightCount) / Double(max(sampleCount, 1)) >= 0.25
            }
        }
        return ZebraMask(columns: safeColumns, rows: safeRows, activeCells: active)
    }
}

struct ZebraExposureOverlay: View {
    let mask: ZebraMask

    var body: some View {
        Canvas { context, size in
            let cellWidth = size.width / CGFloat(mask.columns)
            let cellHeight = size.height / CGFloat(mask.rows)
            let stripeSpacing: CGFloat = 8

            for row in 0..<mask.rows {
                for column in 0..<mask.columns where mask.isActive(column: column, row: row) {
                    let rect = CGRect(
                        x: CGFloat(column) * cellWidth,
                        y: CGFloat(row) * cellHeight,
                        width: cellWidth + 1,
                        height: cellHeight + 1
                    )
                    var cellContext = context
                    cellContext.clip(to: Path(rect))
                    var x = rect.minX - rect.height
                    while x < rect.maxX + rect.height {
                        var stripe = Path()
                        stripe.move(to: CGPoint(x: x, y: rect.maxY))
                        stripe.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
                        cellContext.stroke(stripe, with: .color(.yellow.opacity(0.8)), lineWidth: 2)
                        x += stripeSpacing
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
