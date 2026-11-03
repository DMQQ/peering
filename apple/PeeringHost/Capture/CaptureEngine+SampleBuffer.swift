import CoreMedia
import CoreGraphics
import Foundation
import ScreenCaptureKit

extension CaptureEngine {
    // MARK: - Sample buffer decoding

/// Read from the sample attachments array, not a buffer-level attachment: ScreenCaptureKit attaches nothing at buffer level, so `CMGetAttachment` answers `nil`, every frame is classified as one to drop, and it looks exactly like a denied Screen Recording permission.
    struct FrameInfo {
        let status: SCFrameStatus?
        let values: [SCStreamFrameInfo: Any]
    }

    static func frameInfo(of sampleBuffer: CMSampleBuffer) -> FrameInfo? {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer, createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]], let first = attachments.first else { return nil }

        return FrameInfo(
            status: (first[.status] as? NSNumber).flatMap { SCFrameStatus(rawValue: $0.intValue) },
            values: first
        )
    }

    static func geometry(from info: FrameInfo?) -> FrameGeometry {
        FrameGeometry(
            contentRect: rect(info?.values[.contentRect]),
            contentScale: (info?.values[.contentScale] as? NSNumber).map { CGFloat($0.doubleValue) },
            scaleFactor: (info?.values[.scaleFactor] as? NSNumber).map { CGFloat($0.doubleValue) },
            screenRect: rect(info?.values[.screenRect])
        )
    }

/// Two representations arrive depending on the key: an `NSValue` wrapping a `CGRect`, and a `dictionaryRepresentation`. Guessing wrong yields a nil rect and a drifting cursor.
    private static func rect(_ value: Any?) -> CGRect? {
        if let value = value as? NSValue { return value.rectValue }
        if let value = value as? NSDictionary { return CGRect(dictionaryRepresentation: value as CFDictionary) }
        return nil
    }
}
