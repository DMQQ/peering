package pl.dmq.peering.platform.audio

import android.content.Context
import pl.dmq.peering.platform.PlatformLog
import pl.dmq.peering.session.audio.AudioBacklog
import pl.dmq.peering.session.audio.AudioStreamFormat
import pl.dmq.peering.session.audio.FocusState
import pl.dmq.peering.session.audio.PcmFrames
import pl.dmq.peering.session.audio.SoundConditions
import pl.dmq.peering.session.audio.SoundOutput
import pl.dmq.peering.wire.AudioStreamConfig
import pl.dmq.peering.wire.EncodedAudioFrame

/**
 * The computer's sound on this phone. The stream's callbacks come from a network thread and the controls from the main
 * thread, so every entry point takes this object's monitor. While the sound is silenced the pump and the track are released and frames are dropped, not queued.
 */
class ComputerSound(context: Context) {
    private val focus = SoundFocus(context.applicationContext, ::onFocusChange)
    private val routeWatch = RouteLossWatch(context.applicationContext, ::onRouteLost)
    private var format: AudioStreamFormat? = null
    private var backlog: AudioBacklog? = null
    private var pump: AudioTrackPump? = null
    private var pumpFailed = false
    private var muted = false
    private var appInForeground = true
    private var focusState = FocusState.NONE
    private var routeLost = false

    @Synchronized
    fun onConfig(config: AudioStreamConfig) {
        teardown()
        val next = AudioStreamFormat.of(config) ?: return
        format = next
        backlog = AudioBacklog(next)
        pumpFailed = false
        routeWatch.start()
        reconcile()
    }

    @Synchronized
    fun onFrame(frame: EncodedAudioFrame) {
        val current = format ?: return
        if (pump == null) return
        val samples = PcmFrames.toOutput(frame, current) ?: return
        backlog?.offer(samples)
    }

    /** The session ended: release the speaker and the focus. */
    @Synchronized
    fun stop() {
        teardown()
        routeLost = false
    }

    @Synchronized
    fun setMuted(muted: Boolean) {
        if (this.muted == muted) return
        this.muted = muted
        routeLost = false
        reconcile()
    }

    @Synchronized
    fun setAppInForeground(inForeground: Boolean) {
        if (appInForeground == inForeground) return
        appInForeground = inForeground
        if (inForeground) routeLost = false
        reconcile()
    }

    @Synchronized
    private fun onFocusChange(state: FocusState) {
        focusState = state
        reconcile()
    }

    @Synchronized
    private fun onRouteLost() {
        routeLost = true
        reconcile()
    }

    private fun teardown() {
        closePump()
        routeWatch.stop()
        focus.release()
        focusState = FocusState.NONE
        format = null
        backlog = null
    }

    private fun reconcile() {
        val current = format ?: return
        val wants = SoundConditions(muted, appInForeground, focusState, routeLost).wantsFocus
        if (!wants && focusState != FocusState.NONE) {
            focus.release()
            focusState = FocusState.NONE
        }
        if (wants && focusState == FocusState.NONE) focusState = focus.acquire()
        val output = SoundConditions(muted, appInForeground, focusState, routeLost).output
        if (output == SoundOutput.SILENT) {
            closePump()
            return
        }
        val playing = pump ?: openPump(current)
        playing?.setVolume(output.volume)
    }

    private fun openPump(current: AudioStreamFormat): AudioTrackPump? {
        val queue = backlog ?: return null
        if (pumpFailed) return null
        return try {
            AudioTrackPump(current, queue, SoundOutput.FULL.volume).also { pump = it }
        } catch (error: IllegalArgumentException) {
            failPump(error)
        } catch (error: IllegalStateException) {
            failPump(error)
        } catch (error: UnsupportedOperationException) {
            failPump(error)
        }
    }

    private fun failPump(error: Exception): AudioTrackPump? {
        pumpFailed = true
        PlatformLog.w(TAG, { "the speaker could not be opened for this stream" }, error)
        return null
    }

    private fun closePump() {
        pump?.close()
        pump = null
        backlog?.clear()
    }

    private companion object {
        const val TAG = "PeeringSound"
    }
}
