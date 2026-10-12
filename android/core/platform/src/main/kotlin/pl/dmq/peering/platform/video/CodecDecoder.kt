package pl.dmq.peering.platform.video

import android.media.MediaCodec
import android.media.MediaCodecList
import android.media.MediaFormat
import android.os.Build
import android.view.Surface
import java.nio.ByteBuffer
import pl.dmq.peering.session.ports.VideoSink
import pl.dmq.peering.wire.EncodedVideoFrame
import pl.dmq.peering.wire.VideoCodecProbe
import pl.dmq.peering.wire.VideoStreamConfig
import pl.dmq.peering.wire.avccToAnnexB

/**
 * Decodes straight to a Surface. Frames arrive from one thread, in decode order. A frame that cannot be queued is
 * dropped and the decoder waits for the next keyframe, so a stall costs a moment of picture, not the stream.
 */
class CodecDecoder(private val surface: Surface) : VideoSink {
    private var codec: MediaCodec? = null
    private var current: VideoStreamConfig? = null
    private val keyframes = KeyframeLossPolicy()
    private val info = MediaCodec.BufferInfo()

    override fun onConfig(config: VideoStreamConfig) {
        if (config == current) return
        release()
        val decoder = DecoderConfig.from(config, Build.VERSION.SDK_INT)
        val format = MediaFormat.createVideoFormat(decoder.mimeType, decoder.width, decoder.height)
        decoder.csd.forEachIndexed { index, bytes -> format.setByteBuffer("csd-$index", ByteBuffer.wrap(bytes)) }
        decoder.options.forEach { (key, value) -> format.setInteger(key, value) }
        val created = MediaCodec.createDecoderByType(decoder.mimeType)
        created.configure(format, surface, null, 0)
        created.start()
        codec = created
        current = config
        keyframes.onConfigChanged()
    }

    override fun onFrame(frame: EncodedVideoFrame) {
        val decoder = codec ?: return
        if (!keyframes.admit(frame.isKeyframe)) return
        try {
            val queued = queue(decoder, avccToAnnexB(frame.data), presentationMicros(frame))
            if (!queued && keyframes.onInputDropped()) decoder.flush()
            drain(decoder)
        } catch (error: MediaCodec.CodecException) {
            if (keyframes.onDecodeError()) decoder.flush()
        }
    }

    override fun onStop() {
        release()
        current = null
    }

    private fun queue(decoder: MediaCodec, data: ByteArray, presentationUs: Long): Boolean {
        val index = decoder.dequeueInputBuffer(INPUT_TIMEOUT_US)
        if (index < 0) return false
        val buffer = decoder.getInputBuffer(index) ?: return false
        if (data.size > buffer.capacity()) {
            decoder.queueInputBuffer(index, 0, 0, presentationUs, 0)
            return false
        }
        buffer.clear()
        buffer.put(data)
        decoder.queueInputBuffer(index, 0, data.size, presentationUs, 0)
        return true
    }

    private fun drain(decoder: MediaCodec) {
        while (true) {
            val index = decoder.dequeueOutputBuffer(info, 0)
            if (index == MediaCodec.INFO_TRY_AGAIN_LATER) return
            if (index >= 0) decoder.releaseOutputBuffer(index, true)
        }
    }

    private fun release() {
        codec?.let {
            it.stop()
            it.release()
        }
        codec = null
    }

    private fun presentationMicros(frame: EncodedVideoFrame): Long =
        (frame.presentationTime.seconds * MICROS_PER_SECOND).toLong()

    private companion object {
        const val INPUT_TIMEOUT_US = 10_000L
        const val MICROS_PER_SECOND = 1_000_000.0
    }
}

/** The codecs this device can decode, in the names the host uses on the wire, most preferred first. */
fun codecSupport(): List<String> {
    val types = MediaCodecList(MediaCodecList.ALL_CODECS).codecInfos
        .asSequence()
        .filter { !it.isEncoder }
        .flatMap { it.supportedTypes.asSequence() }
        .toList()
    return VideoCodecProbe.codecPreference(types)
}
