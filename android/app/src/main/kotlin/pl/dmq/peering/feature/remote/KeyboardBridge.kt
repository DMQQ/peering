package pl.dmq.peering.feature.remote

import androidx.compose.foundation.layout.size
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.input.key.KeyEvent
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.unit.dp

/**
 * A hidden field that takes the soft keyboard's text and key events. It always holds [SoftKeyboardEdit.SENTINEL], so
 * a delete changes the field instead of leaving it unchanged. Shown while [shown] is true.
 */
@Composable
fun KeyboardBridge(
    presenter: KeyboardPresenter,
    shown: Boolean,
    modifier: Modifier = Modifier,
) {
    val focusRequester = remember { FocusRequester() }
    val keyboard = LocalSoftwareKeyboardController.current
    var field by remember { mutableStateOf(sentinelField()) }

    LaunchedEffect(shown) {
        if (shown) {
            focusRequester.requestFocus()
            keyboard?.show()
        } else {
            keyboard?.hide()
        }
    }

    BasicTextField(
        value = field,
        onValueChange = { next ->
            if (next.composition != null) {
                field = next
                return@BasicTextField
            }
            when (val edit = SoftKeyboardEdit.of(next.text)) {
                is SoftKeyboardEdit.Typed -> presenter.onSoftKeyboardText(edit.text)
                SoftKeyboardEdit.Deleted -> presenter.onSoftKeyboardDelete()
                SoftKeyboardEdit.None -> Unit
            }
            field = sentinelField()
        },
        modifier = modifier
            .size(1.dp)
            .alpha(0f)
            .focusRequester(focusRequester)
            .onPreviewKeyEvent { event -> presenter.onKey(event.toKeyInput()) },
    )
}

private fun sentinelField(): TextFieldValue =
    TextFieldValue(SoftKeyboardEdit.SENTINEL, selection = TextRange(SoftKeyboardEdit.SENTINEL.length))

private fun KeyEvent.toKeyInput(): KeyInput = KeyInput(
    androidKeyCode = nativeKeyEvent.keyCode,
    unicodeChar = nativeKeyEvent.unicodeChar,
    metaState = nativeKeyEvent.metaState.toLong(),
    isDown = type == KeyEventType.KeyDown,
)
