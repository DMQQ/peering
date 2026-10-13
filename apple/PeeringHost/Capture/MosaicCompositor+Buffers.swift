import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import PeeringKit
import RemoteCore
import ScreenCaptureKit
import os

extension MosaicCompositor {
/// The allocation threshold turns back-pressure into a dropped tick: past it the pool refuses and tick() counts it. Three is the encoder queue depth plus the frame being drawn.
    static func makePool(for canvas: CGSize) throws -> CVPixelBufferPool {
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferWidthKey: Int(canvas.width),
            kCVPixelBufferHeightKey: Int(canvas.height),
        ]
        let auxiliaries: [CFString: Any] = [
            kCVPixelBufferPoolAllocationThresholdKey: 3,
        ]
        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            auxiliaries as CFDictionary,
            attributes as CFDictionary,
            &pool
        )
        guard status == kCVReturnSuccess, let pool else {
            throw CaptureError.encodingFailed("A canvas of \(Int(canvas.width))×\(Int(canvas.height)) could not be allocated.")
        }
        return pool
    }

/// Row by row: same-size buffers are not promised the same bytes per row (CoreVideo pads), and a plane copied as one block would shear sideways.
    static func copy(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        guard width > 0, height > 0 else { return nil }

        var destination: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        guard CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            attributes as CFDictionary,
            &destination
        ) == kCVReturnSuccess, let destination else { return nil }

        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(destination, [])
        defer {
            CVPixelBufferUnlockBaseAddress(destination, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }

        for plane in 0..<CVPixelBufferGetPlaneCount(source) {
            guard let from = CVPixelBufferGetBaseAddressOfPlane(source, plane),
                  let to = CVPixelBufferGetBaseAddressOfPlane(destination, plane) else { return nil }
            let rows = CVPixelBufferGetHeightOfPlane(source, plane)
            let sourceStride = CVPixelBufferGetBytesPerRowOfPlane(source, plane)
            let destinationStride = CVPixelBufferGetBytesPerRowOfPlane(destination, plane)
            let bytes = min(sourceStride, destinationStride)
            for row in 0..<rows {
                memcpy(
                    to.advanced(by: row * destinationStride),
                    from.advanced(by: row * sourceStride),
                    bytes
                )
            }
        }
        return destination
    }
}
