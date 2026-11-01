package pl.dmq.peering.feature.sessionmode

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.isImeVisible
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.feature.remote.KeyboardPresenter
import pl.dmq.peering.ui.kit.SessionIcons
import pl.dmq.peering.ui.kit.sessionSurface
import pl.dmq.peering.ui.kit.tappable
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText
import pl.dmq.peering.ui.theme.PillShape

/** Shown while typing so the keys have somewhere visible to land; each keystroke still goes straight to the computer. */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun RemoteDockTypingField(keyboard: KeyboardPresenter, onDone: () -> Unit, modifier: Modifier = Modifier) {
    var typed by remember { mutableStateOf("") }
    val focus = remember { FocusRequester() }
    val ime = LocalSoftwareKeyboardController.current
    val imeShown = WindowInsets.isImeVisible
    var imeWasShown by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) {
        focus.requestFocus()
        ime?.show()
    }
    LaunchedEffect(imeShown) {
        if (imeWasShown && !imeShown) onDone()
        imeWasShown = imeWasShown || imeShown
    }
    Row(
        modifier.fillMaxWidth().height(52.dp).sessionSurface(PillShape).padding(start = 18.dp, end = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(Modifier.weight(1f)) {
            if (typed.isEmpty()) Text(stringResource(R.string.dock_type_hint), style = PeeringText.body, color = PeeringColors.muted, maxLines = 1)
            BasicTextField(
                value = typed,
                onValueChange = { next ->
                    send(keyboard, TypedDiff.of(typed, next))
                    typed = if (next.length > MAX_KEPT) "" else next
                },
                singleLine = true,
                textStyle = PeeringText.body.copy(color = PeeringColors.ink),
                cursorBrush = SolidColor(PeeringColors.ink),
                keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.None, autoCorrectEnabled = false, imeAction = ImeAction.Send),
                keyboardActions = KeyboardActions(onSend = {
                    keyboard.sendKey(RETURN)
                    typed = ""
                }),
                modifier = Modifier.fillMaxWidth().focusRequester(focus),
            )
        }
        HideKeyboardButton(onDone)
    }
}

private fun send(keyboard: KeyboardPresenter, diff: TypedDiff) {
    repeat(diff.deleted) { keyboard.sendKey(DELETE) }
    if (diff.appended.isNotEmpty()) keyboard.onSoftKeyboardText(diff.appended)
}

@Composable
private fun HideKeyboardButton(onClick: () -> Unit) {
    val label = stringResource(R.string.dock_hide_keyboard)
    Box(
        Modifier.size(40.dp).tappable(onClick).semantics { contentDescription = label },
        contentAlignment = Alignment.Center,
    ) {
        Icon(SessionIcons.hideKeyboard, contentDescription = null, tint = PeeringColors.ink, modifier = Modifier.size(20.dp))
    }
}

private const val RETURN = 36
private const val DELETE = 51
private const val MAX_KEPT = 200
