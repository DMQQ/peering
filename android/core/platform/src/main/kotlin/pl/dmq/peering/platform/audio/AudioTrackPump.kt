package pl.dmq.peering.platform.audio

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import pl.dmq.peering.session.audio.AudioBacklog
import pl.dmq.peering.session.audio.AudioStreamFormat

/** Plays what [backlog] yields through a low latency [AudioTrack], on a thread of its own, until [close]. */
internal class AudioTrackPump(format: AudioStreamFormat, private val backlog: AudioBacklog, volume: Float) {
    private val track: AudioTrack = buildTrack(format).also {
        it.setVolume(volume)
        it.play()
    }

    @Volatile
    private var running = true

    private val thread = Thread(::pump, "PeeringSound").also {
        it.priority = Thread.MAX_PRIORITY
        it.start()
    }

    fun setVolume(volume: Float) {
        track.setVolume(volume)
    }

    fun close() {
        running = false
        thread.join(JOIN_MILLIS)
        track.release()
    }

    private fun pump() {
        while (running) {
            val samples = backlog.poll()
            if (samples == null) {
                Thread.sleep(IDLE_MILLIS)
                continue
            }
            track.write(samples, 0, samples.size, AudioTrack.WRITE_BLOCKING)
        }
    }

    private fun buildTrack(format: AudioStreamFormat): AudioTrack {
        val mask = if (format.outputChannels == 1) AudioFormat.CHANNEL_OUT_MONO else AudioFormat.CHANNEL_OUT_STEREO
        val pcm = AudioFormat.Builder()
            .setEncoding(AudioFormat.ENCODING_PCM_FLOAT)
            .setSampleRate(format.sampleRate)
            .setChannelMask(mask)
            .build()
        val minimum = AudioTrack.getMinBufferSize(format.sampleRate, mask, AudioFormat.ENCODING_PCM_FLOAT)
        return AudioTrack.Builder()
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_MOVIE)
                    .build(),
            )
            .setAudioFormat(pcm)
            .setBufferSizeInBytes(maxOf(minimum, 1) * BUFFER_FACTOR)
            .setTransferMode(AudioTrack.MODE_STREAM)
            .setPerformanceMode(AudioTrack.PERFORMANCE_MODE_LOW_LATENCY)
            .build()
    }

    private companion object {
        const val BUFFER_FACTOR = 2
        const val IDLE_MILLIS = 4L
        const val JOIN_MILLIS = 300L
    }
}
