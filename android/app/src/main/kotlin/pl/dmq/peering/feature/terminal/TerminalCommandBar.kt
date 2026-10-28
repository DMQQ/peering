package pl.dmq.peering.feature.terminal

import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import pl.dmq.peering.R
import pl.dmq.peering.ui.kit.tappable
import pl.dmq.peering.ui.theme.PeeringColors

private val capsuleHeight = 48.dp
private val fieldHeight = 30.dp

/** What the bar edits and where its buttons lead. An empty line sends Return on its own. */
class CommandBarState(
    val text: String,
    val onText: (String) -> Unit,
    val isRunning: Boolean,
    val historyVisible: Boolean,
    val hasHistory: Boolean,
    val onToggleHistory: () -> Unit,
    val onSubmit: () -> Unit,
    val onEnter: () -> Unit,
)

/** The input: a 48 dp capsule holding the command field, and the round send button beside it. */
@Composable
fun TerminalCommandBar(state: CommandBarState, focus: FocusRequester, modifier: Modifier = Modifier) {
    var focused by remember { mutableStateOf(false) }
    val focusManager = LocalFocusManager.current
    Row(
        modifier.fillMaxWidth().background(Color.Black).padding(start = 16.dp, end = 16.dp, top = 8.dp, bottom = 6.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Row(
            Modifier.weight(1f).heightIn(min = capsuleHeight).clip(CircleShape).background(PeeringColors.surface)
                .padding(horizontal = 14.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            if (state.hasHistory) {
                BarGlyph(
                    TerminalGlyphs.history,
                    stringResource(if (state.historyVisible) R.string.terminal_history_hide else R.string.terminal_history_show),
                    if (state.historyVisible) PeeringColors.accent else PeeringColors.muted,
                    state.onToggleHistory,
                )
            }
            CommandField(state, focus, Modifier.weight(1f).onFocusChanged { focused = it.isFocused })
            if (focused) {
                BarGlyph(TerminalGlyphs.hideKeyboard, stringResource(R.string.terminal_hide_keyboard), PeeringColors.muted) {
                    focusManager.clearFocus()
                }
            }
        }
        SendButton(state)
    }
}

@Composable
private fun CommandField(state: CommandBarState, focus: FocusRequester, modifier: Modifier) {
    val style = TextStyle(color = PeeringColors.ink, fontSize = 17.sp, fontFamily = FontFamily.Monospace)
    BasicTextField(
        value = state.text,
        onValueChange = state.onText,
        modifier = modifier.height(fieldHeight).focusRequester(focus),
        enabled = state.isRunning,
        singleLine = true,
        textStyle = style,
        visualTransformation = CommandHighlightTransformation,
        cursorBrush = SolidColor(PeeringColors.ink),
        keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.None, autoCorrectEnabled = false, imeAction = ImeAction.Send),
        keyboardActions = KeyboardActions(onSend = { state.onSubmit() }),
        decorationBox = { field ->
            Box(Modifier.fillMaxHeight(), contentAlignment = Alignment.CenterStart) {
                if (state.text.isEmpty()) {
                    Text(
                        stringResource(if (state.isRunning) R.string.terminal_placeholder else R.string.terminal_placeholder_exited),
                        style = style.copy(color = PeeringColors.tertiary),
                        maxLines = 1,
                    )
                }
                field()
            }
        },
    )
}

@Composable
private fun BarGlyph(icon: androidx.compose.ui.graphics.vector.ImageVector, description: String, tint: Color, onClick: () -> Unit) {
    Box(Modifier.size(width = 28.dp, height = 36.dp).clip(CircleShape).tappable(onClick), contentAlignment = Alignment.Center) {
        Icon(icon, description, tint = tint, modifier = Modifier.size(17.dp))
    }
}

/** White when there is something to send, quiet when there is not. */
@Composable
private fun SendButton(state: CommandBarState) {
    val empty = state.text.isEmpty()
    val enabled = state.isRunning
    Box(
        Modifier.size(capsuleHeight).railPress(if (empty) state.onEnter else state.onSubmit, enabled, scale = 0.92f)
            .clip(CircleShape).background(if (enabled) PeeringColors.ink else Color.White.copy(alpha = 0.1f)),
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            if (empty) TerminalGlyphs.returnKey else TerminalGlyphs.sendLine,
            stringResource(if (empty) R.string.terminal_enter else R.string.terminal_send),
            tint = if (enabled) PeeringColors.onInk else Color.White.copy(alpha = 0.35f),
            modifier = Modifier.size(20.dp),
        )
    }
}

/** Commands already sent, as monospaced capsules; a tap fills the field instead of sending. */
@Composable
fun TerminalHistoryStrip(history: List<String>, enabled: Boolean, onPick: (String) -> Unit, modifier: Modifier = Modifier) {
    Box(modifier.fillMaxWidth().background(Color.White.copy(alpha = 0.02f))) {
        Row(
            Modifier.horizontalScroll(rememberScrollState()).padding(horizontal = 12.dp, vertical = 7.dp),
            horizontalArrangement = Arrangement.spacedBy(6.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(TerminalGlyphs.history, null, tint = PeeringColors.tertiary, modifier = Modifier.size(12.dp))
            history.forEach { command ->
                Text(
                    command,
                    modifier = Modifier.clip(CircleShape).background(Color.White.copy(alpha = 0.08f))
                        .tappable({ onPick(command) }, enabled).padding(horizontal = 9.dp, vertical = 5.dp),
                    color = PeeringColors.ink,
                    fontSize = 11.sp,
                    fontFamily = FontFamily.Monospace,
                    maxLines = 1,
                )
            }
        }
        HorizontalDivider(Modifier.align(Alignment.TopCenter), color = PeeringColors.hairline)
    }
}
