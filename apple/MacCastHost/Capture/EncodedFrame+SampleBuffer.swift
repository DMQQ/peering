import CoreMedia
import Foundation

extension EncodedFrame {
    /// Copies the encoder's output into a frame, or nil when the sample has no data.
    static func make(
        _ sampleBuffer: CMSampleBuffer,
        codec: VideoCodec,
        geometry: FrameGeometry
    ) -> EncodedFrame? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer)
        else {
            return nil
        }

        // Parameter sets are in the format description, not the frame data; scanning for start codes finds nothing and leaves the first keyframe undecodable.
        let isKeyframe = isSyncFrame(sampleBuffer)

        var parameterSets: [Data] = []
        var nalUnitHeaderLength = 4
        if isKeyframe, let extracted = codec.parameterSets(from: formatDescription) {
            parameterSets = extracted.sets
            nalUnitHeaderLength = extracted.nalUnitHeaderLength
        }

        let length = CMBlockBufferGetDataLength(blockBuffer)
        guard length > 0 else { return nil }

        var data = Data(count: length)
        let copied = data.withUnsafeMutableBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: base)
        }
        guard copied == kCMBlockBufferNoErr else { return nil }

        let dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)

        return EncodedFrame(
            data: data,
            presentationTime: sampleBuffer.presentationTimeStamp,
            duration: sampleBuffer.duration,
            isKeyframe: isKeyframe,
            parameterSets: parameterSets,
            nalUnitHeaderLength: nalUnitHeaderLength,
            codec: codec,
            pixelSize: CGSize(width: Int(dimensions.width), height: Int(dimensions.height)),
            geometry: geometry
        )
    }

    /// Read from sample attachments, not CMGetAttachment: that returns nil for every frame (delta frames are marked NotSync on the sample), which reads as every frame being a keyframe and smears a mid-stream joiner.
    private static func isSyncFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
        guard let attachments, CFArrayGetCount(attachments) > 0,
              let raw = CFArrayGetValueAtIndex(attachments, 0) else {
            // An unmarked sample is a sync sample by definition.
            return true
        }

        let sample = Unmanaged<CFDictionary>.fromOpaque(raw).takeUnretainedValue()
        let markedNotSync = CFDictionaryContainsKey(
            sample,
            Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque()
        )
        return !markedNotSync
    }
}
