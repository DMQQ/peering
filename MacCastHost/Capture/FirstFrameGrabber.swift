import CoreImage
import CoreMedia
import Foundation
import ScreenCaptureKit

/// One frame from a short-lived stream, for a window `SCScreenshotManager` will not photograph.
final class FirstFrameGrabber: NSObject, SCStreamOutput, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<CGImage?, Never>?
    private var result: CGImage?
    private var finished = false
    let queue = DispatchQueue(label: "pl.dmq.peering.host.first-frame")

    private static let context = CIContext()
    private static let timeout: DispatchTimeInterval = .seconds(1)

    static func still(filter: SCContentFilter, configuration: SCStreamConfiguration) async -> CGImage? {
        let grabber = FirstFrameGrabber()
        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        do {
            try stream.addStreamOutput(grabber, type: .screen, sampleHandlerQueue: grabber.queue)
            try await stream.startCapture()
        } catch {
            return nil
        }
        let image = await grabber.firstFrame()
        try? await stream.stopCapture()
        return image
    }

    private func firstFrame() async -> CGImage? {
        await withCheckedContinuation { continuation in
            let early = lock.withLock { () -> Bool in
                guard !finished else { return true }
                self.continuation = continuation
                return false
            }
            if early {
                continuation.resume(returning: lock.withLock { result })
                return
            }
            queue.asyncAfter(deadline: .now() + Self.timeout) { [self] in finish(with: nil) }
        }
    }

    private func finish(with image: CGImage?) {
        let waiting = lock.withLock { () -> CheckedContinuation<CGImage?, Never>? in
            guard !finished else { return nil }
            finished = true
            result = image
            defer { continuation = nil }
            return continuation
        }
        waiting?.resume(returning: image)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        // Frame status is a per-sample attachment; reading it from the buffer's own attachments
        // returns nothing.
        guard type == .screen,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: raw) == .complete,
              let pixels = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }
        let image = CIImage(cvPixelBuffer: pixels)
        finish(with: Self.context.createCGImage(image, from: image.extent))
    }
}
