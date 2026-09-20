import CoreMedia
import Foundation
import RemoteCore

/// Turning one decoded frame of the wire into a sample the renderer can be given.
///
/// Here rather than on the renderer because the three attachments it sets are the whole of
/// what decides whether the picture plays at all, and a renderer needs a display layer, a
/// session and a Mac on the other end to exist. This needs none of them: its attachments are
/// asserted in `MacCastPolicyTests`, without an app bundle.
public enum VideoSampleBuffer {
    /// Wraps one AVCC payload in a `CMSampleBuffer` the renderer can decode.
    ///
    /// `decodeTimeStamp = .invalid` is correct here and is not a shortcut: the host encodes
    /// with `AllowFrameReordering = false`, so presentation order *is* decode order and there
    /// is no second timestamp to supply. Declaring one would make the layer wait for a
    /// reorder that never comes.
    public static func make(
        _ frame: EncodedVideoFrame,
        format: CMVideoFormatDescription
    ) -> CMSampleBuffer? {
        let length = frame.data.count
        guard length > 0 else { return nil }

        // A block buffer owning its own memory, then a copy in. The alternative — pointing at
        // the frame's bytes — would need the `Data` to outlive the sample buffer, which it
        // does not: the caller drops it the moment this returns.
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
        // from the sample attachment dict (CMSampleBufferGetSampleAttachmentsArray), not from
        // the buffer-level bearer (CMSetAttachment/CMGetAttachment). Setting them at the wrong
        // level is silently ignored.
        //
        // DisplayImmediately: bypasses the timebase scheduler so frames render as they arrive
        // rather than being held until their PTS. Without it the renderer buffers frames until
        // its queue is full, isReadyForMoreMediaData stays false, and P-frames are all dropped.
        //
        // NotSync / DependsOnOthers: tell the renderer which frames are independently
        // decodable. Without them every P-frame looks like a sync sample; the renderer tries
        // to present each one independently, which fails, and only actual keyframes display —
        // one every ~2 seconds.
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
