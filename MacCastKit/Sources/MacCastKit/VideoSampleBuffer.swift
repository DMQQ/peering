import CoreMedia
import Foundation
import RemoteCore

/// The attachments decide whether the picture plays at all; they live here so `MacCastPolicyTests` can assert them without an app bundle.
public enum VideoSampleBuffer {
    /// `decodeTimeStamp = .invalid` is correct: the host encodes with `AllowFrameReordering` false,
    /// so presentation order is decode order and there is no second timestamp to supply.
    public static func make(
        _ frame: EncodedVideoFrame,
        format: CMVideoFormatDescription
    ) -> CMSampleBuffer? {
        let length = frame.data.count
        guard length > 0 else { return nil }

        // A block buffer owning its own memory, then a copy in: pointing at the frame's bytes would
        // need the `Data` to outlive the sample buffer, and the caller drops it on return.
        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: length,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: length,
            flags: 0,
            blockBufferOut: &blockBuffer
        ) == kCMBlockBufferNoErr, let blockBuffer else {
            return nil
        }

        let copied = frame.data.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(
                with: base,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: length
            )
        }
        guard copied == kCMBlockBufferNoErr else { return nil }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: Self.time(from: frame.presentationTime),
            decodeTimeStamp: .invalid
        )
        var sampleSize = length
        var sampleBuffer: CMSampleBuffer?

        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        ) == noErr, let sampleBuffer else {
            return nil
        }

        // All three keys are sample-level attachments. AVSampleBufferVideoRenderer reads them
        // from CMSampleBufferGetSampleAttachmentsArray, not from the buffer-level bearer, and
        // setting them at the wrong level is silently ignored.
        //
        // DisplayImmediately bypasses the timebase scheduler, so frames render as they arrive
        // rather than being held until their PTS; without it the renderer buffers until its queue
        // is full and P-frames are dropped.
        //
        // NotSync and DependsOnOthers say which frames are independently decodable; without them
        // every P-frame looks like a sync sample and only keyframes display.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0,
           let rawDict = CFArrayGetValueAtIndex(attachments, 0) {
            let dict = Unmanaged<CFMutableDictionary>.fromOpaque(rawDict).takeUnretainedValue()
            let isKeyframe = frame.isKeyframe
            func set(_ key: CFString, _ value: CFBoolean) {
                CFDictionarySetValue(
                    dict,
                    Unmanaged.passUnretained(key).toOpaque(),
                    Unmanaged.passUnretained(value).toOpaque()
                )
            }
            set(kCMSampleAttachmentKey_DisplayImmediately, kCFBooleanTrue)
            set(kCMSampleAttachmentKey_NotSync,            isKeyframe ? kCFBooleanFalse : kCFBooleanTrue)
            set(kCMSampleAttachmentKey_DependsOnOthers,    isKeyframe ? kCFBooleanFalse : kCFBooleanTrue)
        }

        return sampleBuffer
    }

    private static func time(from timestamp: VideoTimestamp) -> CMTime {
        // A zero timescale is invalid to CoreMedia and arrives off the network, so it is
        // replaced rather than trusted. 600 is the conventional H.264 timescale.
        let timescale = timestamp.timescale > 0 ? timestamp.timescale : 600
        return CMTime(value: timestamp.value, timescale: CMTimeScale(timescale))
    }
}
