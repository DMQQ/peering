package pl.dmq.peering.session.clipboard

import pl.dmq.peering.wire.CONTROL_CHUNK_SIZE
import pl.dmq.peering.wire.Frame
import pl.dmq.peering.wire.MAX_CLIPBOARD_IMAGE_BYTES
import pl.dmq.peering.wire.MessageKind
import pl.dmq.peering.wire.PushClipboardImage
import pl.dmq.peering.wire.ServerHello
import pl.dmq.peering.wire.VideoChunkEncoder
import pl.dmq.peering.wire.toBase64

/** A picture does not fit one control message, so it travels as chunks of a command, and only to a host that declared it. */
internal sealed interface ClipboardImageFrames {
    class Ready(val frames: List<Frame>) : ClipboardImageFrames

    class Refused(val reason: ClipboardPush) : ClipboardImageFrames

    companion object {
        fun build(host: ServerHello, png: ByteArray, frameId: Long): ClipboardImageFrames {
            if (host.supportsClipboardImages != true) return Refused(ClipboardPush.Unsupported)
            if (png.size > MAX_CLIPBOARD_IMAGE_BYTES) return Refused(ClipboardPush.TooLarge(png.size))
            val payload = PushClipboardImage(png.toBase64()).toJson().toByteArray(Charsets.UTF_8)
            val frames = VideoChunkEncoder.encode(MessageKind.Command, payload, frameId and FRAME_ID_MASK, CONTROL_CHUNK_SIZE)
            return if (frames.isEmpty()) Refused(ClipboardPush.TooLarge(png.size)) else Ready(frames)
        }

        private const val FRAME_ID_MASK = 0xFFFF_FFFFL
    }
}
