import AVFoundation
import CoreVideo
import Foundation

final class FrameMotionGate {
    private static let thumbnailWidth = 32
    private static let thumbnailHeight = 24
    private static let thumbnailPixelCount = thumbnailWidth * thumbnailHeight

    private let meanDifferenceThreshold: Double
    private var previousThumbnail: [UInt8]?

    init(meanDifferenceThreshold: Double = 3.5) {
        self.meanDifferenceThreshold = meanDifferenceThreshold
    }

    func reset() {
        previousThumbnail = nil
    }

    func shouldRunInference(sampleBuffer: CMSampleBuffer, forceInference: Bool) -> Bool {
        guard let thumbnail = makeThumbnail(from: sampleBuffer) else {
            return true
        }

        defer {
            previousThumbnail = thumbnail
        }

        guard !forceInference, let previousThumbnail else {
            return true
        }

        return meanAbsoluteDifference(thumbnail, previousThumbnail) >= meanDifferenceThreshold
    }

    private func makeThumbnail(from sampleBuffer: CMSampleBuffer) -> [UInt8]? {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return nil
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        if CVPixelBufferGetPlaneCount(pixelBuffer) > 0 {
            return makePlanarLumaThumbnail(from: pixelBuffer)
        }

        return makePackedThumbnail(from: pixelBuffer)
    }

    private func makePlanarLumaThumbnail(from pixelBuffer: CVPixelBuffer) -> [UInt8]? {
        guard let baseAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else {
            return nil
        }

        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        guard width > 0, height > 0, bytesPerRow > 0 else {
            return nil
        }

        let base = baseAddress.assumingMemoryBound(to: UInt8.self)
        var thumbnail: [UInt8] = []
        thumbnail.reserveCapacity(Self.thumbnailPixelCount)

        for sampleY in 0..<Self.thumbnailHeight {
            let sourceY = min(height - 1, sampleY * height / Self.thumbnailHeight)
            let row = base.advanced(by: sourceY * bytesPerRow)

            for sampleX in 0..<Self.thumbnailWidth {
                let sourceX = min(width - 1, sampleX * width / Self.thumbnailWidth)
                thumbnail.append(row[sourceX])
            }
        }

        return thumbnail
    }

    private func makePackedThumbnail(from pixelBuffer: CVPixelBuffer) -> [UInt8]? {
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return nil
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        guard width > 0, height > 0, bytesPerRow > 0 else {
            return nil
        }

        switch pixelFormat {
        case kCVPixelFormatType_32BGRA, kCVPixelFormatType_32ARGB, kCVPixelFormatType_32RGBA:
            break
        default:
            return nil
        }

        let base = baseAddress.assumingMemoryBound(to: UInt8.self)
        var thumbnail: [UInt8] = []
        thumbnail.reserveCapacity(Self.thumbnailPixelCount)

        for sampleY in 0..<Self.thumbnailHeight {
            let sourceY = min(height - 1, sampleY * height / Self.thumbnailHeight)
            let row = base.advanced(by: sourceY * bytesPerRow)

            for sampleX in 0..<Self.thumbnailWidth {
                let sourceX = min(width - 1, sampleX * width / Self.thumbnailWidth)
                let pixel = row.advanced(by: sourceX * 4)
                thumbnail.append(luma(fromPackedPixel: pixel, pixelFormat: pixelFormat))
            }
        }

        return thumbnail
    }

    private func luma(fromPackedPixel pixel: UnsafePointer<UInt8>, pixelFormat: OSType) -> UInt8 {
        let red: UInt8
        let green: UInt8
        let blue: UInt8

        switch pixelFormat {
        case kCVPixelFormatType_32ARGB:
            red = pixel[1]
            green = pixel[2]
            blue = pixel[3]
        case kCVPixelFormatType_32RGBA:
            red = pixel[0]
            green = pixel[1]
            blue = pixel[2]
        default:
            blue = pixel[0]
            green = pixel[1]
            red = pixel[2]
        }

        let weighted = UInt16(red) * 77 + UInt16(green) * 150 + UInt16(blue) * 29
        return UInt8(weighted >> 8)
    }

    private func meanAbsoluteDifference(_ current: [UInt8], _ previous: [UInt8]) -> Double {
        guard current.count == previous.count, !current.isEmpty else {
            return .greatestFiniteMagnitude
        }

        var total = 0
        for index in current.indices {
            total += abs(Int(current[index]) - Int(previous[index]))
        }

        return Double(total) / Double(current.count)
    }
}
