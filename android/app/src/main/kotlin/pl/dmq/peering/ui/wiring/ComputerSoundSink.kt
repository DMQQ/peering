package pl.dmq.peering.ui.wiring

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch
import pl.dmq.peering.feature.settings.DevicePrefs
import pl.dmq.peering.platform.audio.ComputerSound
import pl.dmq.peering.session.ports.VideoSink
import pl.dmq.peering.wire.AudioStreamConfig
import pl.dmq.peering.wire.EncodedAudioFrame

/** The picture's sink with the computer's sound played on the side, so the sound does not wait for a surface. */
internal class ComputerSoundSink(private val picture: VideoSink, private val sound: ComputerSound) : VideoSink by picture {
    override fun onAudioConfig(config: AudioStreamConfig) = sound.onConfig(config)

    override fun onAudioFrame(frame: EncodedAudioFrame) = sound.onFrame(frame)

    override fun onStop() {
        picture.onStop()
        sound.stop()
    }
}

/** Keeps [ComputerSound] in step with the sound preference and with whether the app is on screen. */
internal fun ComputerSound.follow(scope: CoroutineScope, prefs: StateFlow<DevicePrefs>, foreground: Flow<Boolean>) {
    scope.launch { prefs.map { !it.playsComputerSound }.distinctUntilChanged().collect(::setMuted) }
    scope.launch { foreground.collect(::setAppInForeground) }
}
