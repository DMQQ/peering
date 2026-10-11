import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import RemoteCore
import os

extension CursorOverlay {
    struct Region {
        let x: Int
        let y: Int
        let width: Int
        let height: Int
    }

    /// The buffers idle frames are built in. The pool only hands over a buffer nothing else holds, so acquiring one answers whether the encoder is finished with it (see acquire(_:)).
    /// More than one: VideoToolbox keeps a frame until the next is encoded and idle frames are unevenly spaced, so a pool of one could be left with nothing to draw in. Each buffer keeps the pixels under its pointer and its own record.
    struct Scratch {
        /// The picture with no pointer in it, as of the last delivered frame; owned here and never handed to the encoder, so always safe to write.
        let picture: CVPixelBuffer
        /// Bumped on every rewrite of picture; a pool buffer holding another number holds a stale screen.
        var generation: UInt64
        var holdsPicture: Bool
        var pictureArrived: Bool

        let pool: CVPixelBufferPool
        let width: Int
        let height: Int
        var geometry: FrameGeometry
        var lastSentTime: CMTime
        var lastInterval: CMTime
        /// Room for the pixels under the pointer, sized for the largest preference rather than the one in force.
        let patchWidth: Int
        let patchHeight: Int
        var buffers: [Buffer]

        /// A ceiling on buffers, in case the pool hands back more than its threshold.
        static let bufferLimit = 4

        struct Buffer {
            /// How a buffer is recognised across acquisitions: the pool hands back a surface, not an object.
            let planeBase: UnsafeMutableRawPointer
            var stride: Int
            var patch: [UInt8]
            /// nil when no pointer is drawn in this buffer; region and patch go together, or a rectangle of picture is put back over a pointer never there.
            var patchRegion: Region?
            /// A different number means the pixels outside the pointer are an older screen.
            var generation: UInt64
        }
    }

    /// The pool is capped at Scratch/bufferLimit and only hands over a buffer nothing else holds, so a failure means the encoder has them all and this sample is dropped. Idle frames go out no faster than the encoder retires them.
    func acquire(_ scratch: Scratch) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
            kCFAllocatorDefault,
            scratch.pool,
            [kCVPixelBufferPoolAllocationThresholdKey: Scratch.bufferLimit] as CFDictionary,
            &buffer
        )
        guard status == kCVReturnSuccess else { return nil }
        return buffer
    }

    /// Made again if the stream's surface changes size. Must be called with the lock held, on the capture queue.
    private func makeScratch(width: Int, height: Int, geometry: FrameGeometry) -> Scratch? {
        // Measured from the shape itself, so changing the outline cannot leave the patch too small to take a pointer back out.
        let box = bounds(tip: .zero, scale: CGFloat(height) * Size.large.fractionOfHeight)
        let patchWidth = Int(box.width.rounded(.up)) + 2
        let patchHeight = Int(box.height.rounded(.up)) + 2
        guard patchWidth > 0, patchHeight > 0 else { return nil }

        let bufferAttributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]

        // Made plainly, not from the pool: it is never handed out, and the pool would subject it to an allocation threshold.
        var picture: CVPixelBuffer?
        guard CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            bufferAttributes as CFDictionary,
            &picture
        ) == kCVReturnSuccess, let picture else { return nil }

        let poolAttributes: [CFString: Any] = [
            // Pool buffers age out after a second by default; an aged-out buffer comes back with nothing of this object's in it.
            kCVPixelBufferPoolMaximumBufferAgeKey: 0,
        ]

        var pool: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            poolAttributes as CFDictionary,
            bufferAttributes as CFDictionary,
            &pool
        ) == kCVReturnSuccess, let pool else { return nil }

        return Scratch(
            picture: picture,
            generation: 0,
            holdsPicture: false,
            pictureArrived: true,
            pool: pool,
            width: width,
            height: height,
            geometry: geometry,
            lastSentTime: .invalid,
            lastInterval: .invalid,
            patchWidth: patchWidth,
            patchHeight: patchHeight,
            buffers: []
        )
    }

    /// Keeps the screen without a pointer, copied before the pointer is drawn into the frame. A failure leaves the picture and generation unchanged, so an idle frame draws over a screen one frame old rather than not at all.
    func refresh(from frame: CVPixelBuffer, geometry: FrameGeometry) {
        let width = CVPixelBufferGetWidthOfPlane(frame, 0)
        let height = CVPixelBufferGetHeightOfPlane(frame, 0)

        lock.withLock {
            var scratch: Scratch
            if let existing = self.scratch, existing.width == width, existing.height == height {
                scratch = existing
            } else {
                // Made and filled in one call: a kept but empty picture is refused until the stream delivers another frame, which a still screen never does.
                guard let fresh = makeScratch(width: width, height: height, geometry: geometry) else {
                    self.scratch = nil
                    return
                }
                scratch = fresh
            }

            // Held across the copy, the one slow moment under this lock (a few hundred microseconds for a display-sized frame).
            guard CVPixelBufferLockBaseAddress(scratch.picture, []) == kCVReturnSuccess else { return }
            defer { CVPixelBufferUnlockBaseAddress(scratch.picture, []) }

            guard Self.copyPicture(from: frame, into: scratch.picture) else { return }
            scratch.generation += 1
            scratch.holdsPicture = true
            scratch.pictureArrived = true
            scratch.geometry = geometry
            self.scratch = scratch
        }
    }

    /// Whole because a delivered frame says the display changed without saying where. Reports success so a half-copied picture does not advance a generation.
    @discardableResult
    static func copyPicture(from source: CVPixelBuffer, into destination: CVPixelBuffer) -> Bool {
        copyPlane(0, from: source, into: destination) && copyPlane(1, from: source, into: destination)
    }

    private static func copyPlane(_ index: Int, from source: CVPixelBuffer, into destination: CVPixelBuffer) -> Bool {
        guard let sourceBase = CVPixelBufferGetBaseAddressOfPlane(source, index),
              let destinationBase = CVPixelBufferGetBaseAddressOfPlane(destination, index)
        else {
            return false
        }

        let sourceStride = CVPixelBufferGetBytesPerRowOfPlane(source, index)
        let destinationStride = CVPixelBufferGetBytesPerRowOfPlane(destination, index)
        let bytes = min(sourceStride, destinationStride)
        let rows = min(
            CVPixelBufferGetHeightOfPlane(source, index),
            CVPixelBufferGetHeightOfPlane(destination, index)
        )
        guard bytes > 0, rows > 0 else { return false }

        let sourceRows = sourceBase.assumingMemoryBound(to: UInt8.self)
        let destinationRows = destinationBase.assumingMemoryBound(to: UInt8.self)
        for row in 0..<rows {
            memcpy(destinationRows + row * destinationStride, sourceRows + row * sourceStride, bytes)
        }
        return true
    }

    func save(
        _ region: Region,
        from plane: UnsafeMutablePointer<UInt8>,
        stride: Int,
        into patch: inout [UInt8]
    ) {
        patch.withUnsafeMutableBufferPointer { destination in
            guard let base = destination.baseAddress else { return }
            for row in 0..<region.height {
                memcpy(
                    base + row * region.width,
                    plane + (region.y + row) * stride + region.x,
                    region.width
                )
            }
        }
    }

    func restore(
        _ region: Region,
        from patch: [UInt8],
        into plane: UnsafeMutablePointer<UInt8>,
        stride: Int
    ) {
        patch.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            for row in 0..<region.height {
                memcpy(
                    plane + (region.y + row) * stride + region.x,
                    base + row * region.width,
                    region.width
                )
            }
        }
    }

    /// The union of every polygon's bounds: a rectangle a pixel too small leaves a trail of arrows.
    func bounds(tip: CGPoint, scale: CGFloat) -> CGRect {
        var minX = CGFloat.greatestFiniteMagnitude
        var minY = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude
        var maxY = -CGFloat.greatestFiniteMagnitude

        for point in vertices {
            let x = tip.x + point.x * scale
            let y = tip.y + point.y * scale
            minX = min(minX, x)
            maxX = max(maxX, x)
            minY = min(minY, y)
            maxY = max(maxY, y)
        }

        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Rounded outward: the rasteriser rounds crossings per row, and a tight box leaves the pointer behind on its outermost row and column.
    static func region(_ box: CGRect, width: Int, height: Int) -> Region? {
        guard box.minX.isFinite, box.minY.isFinite, box.maxX.isFinite, box.maxY.isFinite else {
            return nil
        }
        let first = max(0, Int(box.minX.rounded(.down)))
        let last = min(width - 1, Int(box.maxX.rounded(.up)))
        let top = max(0, Int(box.minY.rounded(.down)))
        let bottom = min(height - 1, Int(box.maxY.rounded(.up)))
        guard last >= first, bottom >= top else { return nil }
        return Region(x: first, y: top, width: last - first + 1, height: bottom - top + 1)
    }
}
