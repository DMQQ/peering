package pl.dmq.peering.feature.terminal

import androidx.compose.foundation.layout.size
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEvent
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.isCtrlPressed
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.input.key.utf16CodePoint
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.unit.dp

/** Stays in the field so a soft keyboard's Backspace has something to delete and shows up as a shorter text. */
private const val SENTINEL = "​"

/**
 * A field nobody sees that owns the keyboard. Everything typed is turned into bytes and the field is put back to
 * its sentinel, so the shell and not the field holds the text. The password type keeps suggestions out of it.
 */
@Composable
fun TerminalInput(keyboard: TerminalKeyboard, focus: FocusRequester, modifier: Modifier = Modifier) {
    var value by remember { mutableStateOf(rest()) }
    BasicTextField(
        value = value,
        onValueChange = { next ->
            when {
                next.text.length < SENTINEL.length -> keyboard.backspace()
                else -> keyboard.type(next.text.replace(SENTINEL, ""))
            }
            value = rest()
        },
        modifier = modifier
            .size(1.dp)
            .focusRequester(focus)
            .onPreviewKeyEvent { event -> handleKey(event, keyboard) },
        textStyle = TextStyle(color = Color.Transparent),
        cursorBrush = SolidColor(Color.Transparent),
        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password, autoCorrectEnabled = false, imeAction = ImeAction.None),
    )
}

private fun rest() = TextFieldValue(SENTINEL, TextRange(SENTINEL.length))

/** Keys a hardware keyboard sends that never reach the field as text. */
private fun handleKey(event: KeyEvent, keyboard: TerminalKeyboard): Boolean {
    if (event.type != KeyEventType.KeyDown) return false
    val extra = when (event.key) {
        Key.Escape -> ExtraKey.ESCAPE
        Key.Tab -> ExtraKey.TAB
        Key.DirectionUp -> ExtraKey.UP
        Key.DirectionDown -> ExtraKey.DOWN
        Key.DirectionLeft -> ExtraKey.LEFT
        Key.DirectionRight -> ExtraKey.RIGHT
        else -> null
    }
    return when {
        extra != null -> keyboard.press(extra).let { true }
        event.key == Key.Enter || event.key == Key.NumPadEnter -> keyboard.enter().let { true }
        event.key == Key.Backspace -> keyboard.backspace().let { true }
        event.isCtrlPressed && event.utf16CodePoint in 0x20..0x7E -> sendControl(event.utf16CodePoint, keyboard)
        else -> false
    }
}

private fun sendControl(codePoint: Int, keyboard: TerminalKeyboard): Boolean {
    if (TerminalKeys.controlCode(codePoint) == null) return false
    keyboard.typeControl(String(Character.toChars(codePoint)))
    return true
}
