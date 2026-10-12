package pl.dmq.peering.feature.remote

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import pl.dmq.peering.wire.KeyDown
import pl.dmq.peering.wire.KeyRoute
import pl.dmq.peering.wire.KeyUp
import pl.dmq.peering.wire.Modifiers
import pl.dmq.peering.wire.RemoteCommand
import pl.dmq.peering.wire.TextInput
import pl.dmq.peering.wire.routeKey

/**
 * Turns keyboard input into commands: printable text is typed as text, other keys are pressed by their macOS keycode.
 * A latched modifier is held for the key that follows it. Not thread safe.
 */
class KeyboardPresenter(
    private val sink: CommandSink,
    private val mode: () -> KeyboardMode = { KeyboardMode.UNICODE },
) {
    private val sticky = StickyModifiers()
    private val latchStates = MutableStateFlow(sticky.latches())
    val latches: StateFlow<Map<StickyModifier, ModifierLatch>> = latchStates.asStateFlow()
    private val preview = MutableStateFlow("")

    /** What has been typed since the last Enter, for the "Typing" line: the phone holds no text, the computer does. */
    val typedPreview: StateFlow<String> = preview.asStateFlow()

    fun onModifierTap(modifier: StickyModifier, timeMs: Long) {
        send(sticky.tap(modifier, timeMs))
    }

    fun onFunctionKey(key: FunctionKey) {
        pressKey(key.macKeyCode)
    }

    fun onEditingKey(key: EditingKey) {
        pressKey(key.macKeyCode)
    }

    /** Text committed by the soft keyboard. */
    fun onSoftKeyboardText(text: String) {
        if (text.isEmpty()) return
        typeText(text)
    }

    /** A delete from the soft keyboard, which is the Backspace key. */
    fun onSoftKeyboardDelete() {
        preview.value = preview.value.dropLast(1)
        pressKey(BACKSPACE_KEY)
    }

    /** Presses [macKeyCode] with [modifiers] and whatever is latched, as the dock's keys and the shortcuts do. */
    fun sendKey(macKeyCode: Int, modifiers: Long = 0L) {
        pressKeyWithoutRelease(macKeyCode, modifiers)
        endKeyPress()
    }

    fun pressEnter() {
        preview.value = ""
        pressKey(RETURN_KEY)
    }

    /** Returns true when the event was sent, so the caller can keep it from the field it came from. */
    fun onKey(input: KeyInput): Boolean =
        when (val route = routeKey(input.unicodeChar, input.androidKeyCode, input.metaState)) {
            is KeyRoute.Text -> {
                if (input.isDown) typeText(String(Character.toChars(route.codepoint)))
                true
            }
            is KeyRoute.Key -> {
                routeKeyEvent(route, input.isDown)
                true
            }
            KeyRoute.Ignored -> false
        }

    private fun routeKeyEvent(route: KeyRoute.Key, isDown: Boolean) {
        val modifiers = Modifiers(route.modifiers or sticky.activeModifiers().bits)
        if (isDown) {
            sink.send(KeyDown(route.macKeyCode, modifiers))
            if (route.macKeyCode !in MODIFIER_KEY_CODES) endKeyPress()
        } else {
            sink.send(KeyUp(route.macKeyCode, modifiers))
        }
    }

    private fun typeText(text: String) {
        preview.value = (preview.value + text).takeLast(PREVIEW_LIMIT)
        if (!sticky.hasActive() && mode() == KeyboardMode.UNICODE) {
            sink.send(TextInput(text))
            return
        }
        text.codePoints().forEach { codepoint ->
            val macKeyCode = macKeyForCharacter(codepoint)
            if (macKeyCode == null) {
                sink.send(TextInput(String(Character.toChars(codepoint))))
            } else {
                val shift = if (Character.isUpperCase(codepoint)) Modifiers.SHIFT else 0L
                pressKeyWithoutRelease(macKeyCode, shift)
            }
        }
        endKeyPress()
    }

    private fun pressKey(macKeyCode: Int) {
        pressKeyWithoutRelease(macKeyCode)
        endKeyPress()
    }

    private fun pressKeyWithoutRelease(macKeyCode: Int, extraModifiers: Long = 0L) {
        val modifiers = Modifiers(extraModifiers or sticky.activeModifiers().bits)
        sink.send(KeyDown(macKeyCode, modifiers))
        sink.send(KeyUp(macKeyCode, modifiers))
    }

    private fun endKeyPress() {
        send(sticky.afterKey())
    }

    private fun send(commands: List<RemoteCommand>) {
        commands.forEach(sink::send)
        latchStates.value = sticky.latches()
    }

    private companion object {
        const val BACKSPACE_KEY = 51
        const val RETURN_KEY = 36
        const val PREVIEW_LIMIT = 200

        /** Both sides of Shift, Control, Option and Command. Caps Lock is an ordinary key here. */
        val MODIFIER_KEY_CODES = setOf(54, 55, 56, 58, 59, 60, 61, 62)
    }
}
