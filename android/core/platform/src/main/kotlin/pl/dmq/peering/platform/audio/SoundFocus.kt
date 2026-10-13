package pl.dmq.peering.platform.audio

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import pl.dmq.peering.session.audio.FocusState

/**
 * Asks the system for the right to play and reports how it changes. The sound may duck other apps but never pauses them,
 * as the iPhone's mix-with-others session does; a call or an app that insists takes focus away and the sound waits.
 */
internal class SoundFocus(context: Context, private val onChange: (FocusState) -> Unit) {
    private val audioManager = context.getSystemService(AudioManager::class.java)
    private var request: AudioFocusRequest? = null

    private val listener = AudioManager.OnAudioFocusChangeListener { change ->
        onChange(
            when (change) {
                AudioManager.AUDIOFOCUS_GAIN -> FocusState.HELD
                AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK -> FocusState.DUCKED
                else -> FocusState.LOST
            },
        )
    }

    /** The state after asking. Asking again while holding is harmless. */
    fun acquire(): FocusState {
        val granted = request ?: AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK)
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_MOVIE)
                    .build(),
            )
            .setOnAudioFocusChangeListener(listener)
            .build()
            .also { request = it }
        return if (audioManager.requestAudioFocus(granted) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED) {
            FocusState.HELD
        } else {
            FocusState.LOST
        }
    }

    fun release() {
        request?.let(audioManager::abandonAudioFocusRequest)
        request = null
    }
}
