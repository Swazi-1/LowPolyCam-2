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
    let sourceWidth: Int
    let sourceHeight: Int
    let pixelFormat: UInt32
    let lumaRange: String
    let isMirrored: Bool
    let rotationAngle: Double

    static let empty = ZebraMask(columns: 24, rows: 16, activeCells: [])

    init(
        columns: Int,
        rows: Int,
        activeCells: [Bool],
        sourceWidth: Int = 0,
        sourceHeight: Int = 0,
        pixelFormat: UInt32 = 0,
        lumaRange: String = "unknown",
        isMirrored: Bool = false,
        rotationAngle: Double = 0
    ) {
        self.columns = max(columns, 1)
        self.rows = max(rows, 1)
        self.activeCells = activeCells
        self.sourceWidth = max(sourceWidth, 0)
        self.sourceHeight = max(sourceHeight, 0)
        self.pixelFormat = pixelFormat
        self.lumaRange = lumaRange
        self.isMirrored = isMirrored
        self.rotationAngle = rotationAngle
    }

    var sourceAspectRatio: CGFloat {
        guard sourceWidth > 0, sourceHeight > 0 else { return 0 }
        return CGFloat(sourceWidth) / CGFloat(sourceHeight)
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
/// video-data output and never touches the movie-file or photo output buffers. The analyzer keeps
/// the source geometry/range on the mask so the SwiftUI overlay can reproduce the preview's
/// aspect-fill crop instead of stretching a sensor grid over the whole screen.
enum ZebraExposureAnalyzer {
    static func analyze(
        sampleBuffer: CMSampleBuffer,
        connection: AVCaptureConnection? = nil,
        columns: Int = 24,
        rows: Int = 16
    ) -> ZebraMask {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return ZebraMask(columns: columns, rows: rows, activeCells: [])
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let width: Int
        let height: Int
        let bytesPerRow: Int
        let baseAddress: UnsafeMutableRawPointer?
        let lumaRange: String
        let isTenBit: Bool
        let isVideoRange: Bool
        let isFullRange: Bool
        let isBGRA: Bool
        if CVPixelBufferIsPlanar(pixelBuffer), CVPixelBufferGetPlaneCount(pixelBuffer) > 0 {
            width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
            height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
            bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
            baseAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)
            isTenBit = pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange ||
                pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
            isVideoRange = pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
                pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            isFullRange = pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ||
                pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
            isBGRA = false
            lumaRange = isVideoRange ? "video" : isFullRange ? "full" : "unsupported"
        } else {
            width = CVPixelBufferGetWidth(pixelBuffer)
            height = CVPixelBufferGetHeight(pixelBuffer)
            bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
            baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer)
            isTenBit = false
            isVideoRange = false
            isFullRange = pixelFormat == kCVPixelFormatType_32BGRA
            isBGRA = pixelFormat == kCVPixelFormatType_32BGRA
            lumaRange = isBGRA ? "full" : "unsupported"
        }
        guard width > 0, height > 0, bytesPerRow > 0, let baseAddress else {
            return ZebraMask(
                columns: columns,
                rows: rows,
                activeCells: [],
                pixelFormat: UInt32(pixelFormat),
                lumaRange: lumaRange,
                isMirrored: connection?.isVideoMirrored ?? false,
                rotationAngle: Double(connection?.videoRotationAngle ?? 0)
            )
        }

        guard isVideoRange || isFullRange else {
            return ZebraMask(
                columns: columns,
                rows: rows,
                activeCells: [],
                sourceWidth: width,
                sourceHeight: height,
                pixelFormat: UInt32(pixelFormat),
                lumaRange: lumaRange,
                isMirrored: connection?.isVideoMirrored ?? false,
                rotationAngle: Double(connection?.videoRotationAngle ?? 0)
            )
        }

        let luma = baseAddress.assumingMemoryBound(to: UInt8.self)
        let safeColumns = max(columns, 1)
        let safeRows = max(rows, 1)
        var active = Array(repeating: false, count: safeColumns * safeRows)
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
                        let normalized: Double
                        if isTenBit {
                            // Bi-planar 10-bit Core Video luma stores the 10 significant bits in
                            // the high bits of a little-endian 16-bit word.
                            let byteOffset = y * bytesPerRow + x * 2
                            guard byteOffset + 1 < y * bytesPerRow + bytesPerRow else { continue }
                            let raw = UInt16(luma[byteOffset]) | (UInt16(luma[byteOffset + 1]) << 8)
                            let code = Double(raw >> 6)
                            normalized = isVideoRange
                                ? (code - 64.0) / (940.0 - 64.0)
                                : code / 1023.0
                        } else if isBGRA {
                            let byteOffset = y * bytesPerRow + x * 4
                            guard byteOffset + 2 < y * bytesPerRow + bytesPerRow else { continue }
                            let blue = Double(luma[byteOffset])
                            let green = Double(luma[byteOffset + 1])
                            let red = Double(luma[byteOffset + 2])
                            normalized = (0.114 * blue + 0.587 * green + 0.299 * red) / 255.0
                        } else {
                            let code = Double(luma[y * bytesPerRow + x])
                            normalized = isVideoRange
                                ? (code - 16.0) / (235.0 - 16.0)
                                : code / 255.0
                        }
                        if min(max(normalized, 0), 1) >= 0.98 { highlightCount += 1 }
                        sampleCount += 1
                    }
                }
                active[row * safeColumns + column] = Double(highlightCount) / Double(max(sampleCount, 1)) >= 0.25
            }
        }
        return ZebraMask(
            columns: safeColumns,
            rows: safeRows,
            activeCells: active,
            sourceWidth: width,
            sourceHeight: height,
            pixelFormat: UInt32(pixelFormat),
            lumaRange: lumaRange,
            isMirrored: connection?.isVideoMirrored ?? false,
            rotationAngle: Double(connection?.videoRotationAngle ?? 0)
        )
    }

    static func pixelFormatName(_ pixelFormat: OSType) -> String {
        switch pixelFormat {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange: return "420v-8bit-video-range"
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange: return "420f-8bit-full-range"
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange: return "x420-10bit-video-range"
        case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange: return "xf44-10bit-full-range"
        case kCVPixelFormatType_32BGRA: return "BGRA-8bit-full-range"
        default: return String(format: "0x%08X", pixelFormat)
        }
    }
}

struct ZebraExposureOverlay: View {
    let mask: ZebraMask

    var body: some View {
        Canvas { context, size in
            let sourceAspect = mask.sourceAspectRatio > 0
                ? (mask.rotationUsesSwappedAspect ? 1 / mask.sourceAspectRatio : mask.sourceAspectRatio)
                : max(size.width / max(size.height, 1), 0.01)
            let viewAspect = max(size.width / max(size.height, 1), 0.01)
            let contentWidth: CGFloat
            let contentHeight: CGFloat
            if sourceAspect > viewAspect {
                contentHeight = size.height
                contentWidth = contentHeight * sourceAspect
            } else {
                contentWidth = size.width
                contentHeight = contentWidth / sourceAspect
            }
            let contentOrigin = CGPoint(
                x: (size.width - contentWidth) / 2,
                y: (size.height - contentHeight) / 2
            )
            let stripeSpacing: CGFloat = 8

            for row in 0..<mask.rows {
                for column in 0..<mask.columns where mask.isActive(column: column, row: row) {
                    let sourceMinX = CGFloat(column) / CGFloat(mask.columns)
                    let sourceMaxX = CGFloat(column + 1) / CGFloat(mask.columns)
                    let sourceMinY = CGFloat(row) / CGFloat(mask.rows)
                    let sourceMaxY = CGFloat(row + 1) / CGFloat(mask.rows)
                    let transformed = [
                        mask.displayPoint(x: sourceMinX, y: sourceMinY),
                        mask.displayPoint(x: sourceMaxX, y: sourceMinY),
                        mask.displayPoint(x: sourceMinX, y: sourceMaxY),
                        mask.displayPoint(x: sourceMaxX, y: sourceMaxY)
                    ]
                    let rect = CGRect(
                        x: contentOrigin.x + transformed.map(\.x).min()! * contentWidth,
                        y: contentOrigin.y + transformed.map(\.y).min()! * contentHeight,
                        width: (transformed.map(\.x).max()! - transformed.map(\.x).min()!) * contentWidth + 1,
                        height: (transformed.map(\.y).max()! - transformed.map(\.y).min()!) * contentHeight + 1
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

private extension ZebraMask {
    var rotationUsesSwappedAspect: Bool {
        let normalized = Int(rotationAngle.rounded()) % 360
        return normalized == 90 || normalized == 270 || normalized == -90 || normalized == -270
    }

    func displayPoint(x: CGFloat, y: CGFloat) -> CGPoint {
        let normalized = ((rotationAngle.truncatingRemainder(dividingBy: 360)) + 360).truncatingRemainder(dividingBy: 360)
        let point: CGPoint
        switch normalized {
        case 45..<135:
            point = CGPoint(x: 1 - y, y: x)
        case 135..<225:
            point = CGPoint(x: 1 - x, y: 1 - y)
        case 225..<315:
            point = CGPoint(x: y, y: 1 - x)
        default:
            point = CGPoint(x: x, y: y)
        }
        return isMirrored ? CGPoint(x: 1 - point.x, y: point.y) : point
    }
}
