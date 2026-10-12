package pl.dmq.peering.feature.terminal

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue

/**
 * Turns taps and typing into bytes for the selected shell. Ctrl and Alt are latches: they apply to the next key or
 * character and clear, the way a soft keyboard without a held modifier has to work.
 */
class TerminalKeyboard(private val sendBytes: (ByteArray) -> Unit) {
    var ctrl by mutableStateOf(false)
        private set
    var alt by mutableStateOf(false)
        private set

    fun toggleCtrl() {
        ctrl = !ctrl
    }

    fun toggleAlt() {
        alt = !alt
    }

    fun press(key: ExtraKey) {
        sendBytes(TerminalKeys.bytes(key, alt))
        release()
    }

    fun type(text: String) {
        if (text.isEmpty()) return
        sendBytes(TerminalKeys.bytes(text, ctrl, alt))
        release()
    }

    /** A character struck with Ctrl held on a hardware keyboard. */
    fun typeControl(text: String) {
        sendBytes(TerminalKeys.bytes(text, ctrl = true, alt = alt))
        release()
    }

    fun backspace() {
        sendBytes(byteArrayOf(TerminalKeys.DELETE.toByte()))
        release()
    }

    fun enter() {
        sendBytes(byteArrayOf(TerminalKeys.RETURN.toByte()))
        release()
    }

    /** Pasted text goes through untouched: a held Ctrl would otherwise swallow its first letter. */
    fun paste(text: String) {
        if (text.isNotEmpty()) sendBytes(TerminalKeys.bytes(text))
    }

    private fun release() {
        ctrl = false
        alt = false
    }
}
