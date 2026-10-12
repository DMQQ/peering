package pl.dmq.peering.feature.agents

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import pl.dmq.peering.R
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText
import pl.dmq.peering.ui.theme.PillShape

private val barHeight = 48.dp

/** The options chips over a pill field and a round send button that becomes Queue while a turn runs and Stop when empty. */
@Composable
fun Composer(presenter: ComposerPresenter, chip: ContextChip?, onShowUsage: () -> Unit, modifier: Modifier = Modifier) {
    val ui by presenter.ui.collectAsState()
    Column(modifier.fillMaxWidth()) {
        OptionsBar(ui, chip, presenter::setPermissionMode, presenter::setModel, onShowUsage)
        Row(
            modifier = Modifier.fillMaxWidth().padding(start = 16.dp, end = 16.dp, top = 8.dp, bottom = 6.dp),
            verticalAlignment = Alignment.Bottom,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            MessageField(ui, presenter::onTextChanged, Modifier.weight(1f))
            SendButton(ui.action, ui.actionEnabled, presenter::send, presenter::stop)
        }
    }
}

@Composable
private fun MessageField(ui: ComposerUi, onChange: (String) -> Unit, modifier: Modifier) {
    var focused by remember { mutableStateOf(false) }
    val border = if (focused) PeeringColors.ink.copy(alpha = 0.3f) else PeeringColors.hairline
    BasicTextField(
        value = ui.text,
        onValueChange = onChange,
        enabled = ui.sessionID != null,
        modifier = modifier.onFocusChanged { focused = it.isFocused },
        textStyle = PeeringText.body.copy(fontSize = 16.sp, color = PeeringColors.ink),
        cursorBrush = SolidColor(PeeringColors.ink),
        maxLines = 6,
        decorationBox = { field ->
            Box(
                Modifier
                    .fillMaxWidth()
                    .heightIn(min = barHeight)
                    .clip(PillShape)
                    .background(PeeringColors.surface)
                    .border(1.dp, border, PillShape)
                    .padding(horizontal = 18.dp, vertical = 12.dp),
                contentAlignment = Alignment.CenterStart,
            ) {
                if (ui.text.isEmpty()) {
                    Text(
                        stringResource(if (ui.action == ComposerAction.SEND) R.string.composer_placeholder else R.string.composer_placeholder_queue),
                        style = PeeringText.body.copy(fontSize = 16.sp),
                        color = PeeringColors.ink.copy(alpha = 0.4f),
                    )
                }
                field()
            }
        },
    )
}

@Composable
private fun SendButton(action: ComposerAction, enabled: Boolean, onSend: () -> Unit, onStop: () -> Unit) {
    val stopping = action == ComposerAction.STOP
    val fill = when {
        !enabled -> PeeringColors.ink.copy(alpha = 0.1f)
        stopping -> PeeringColors.ink.copy(alpha = 0.16f)
        else -> PeeringColors.ink
    }
    val glyph = when {
        !enabled -> PeeringColors.ink.copy(alpha = 0.35f)
        stopping -> PeeringColors.ink
        else -> PeeringColors.onInk
    }
    val label = stringResource(
        when (action) {
            ComposerAction.SEND -> R.string.composer_send
            ComposerAction.QUEUE -> R.string.composer_queue
            ComposerAction.STOP -> R.string.composer_stop
        },
    )
    Box(
        modifier = Modifier
            .size(barHeight)
            .clip(PillShape)
            .background(fill)
            .clickable(enabled = enabled, role = Role.Button, onClick = if (stopping) onStop else onSend)
            .semantics { contentDescription = label },
        contentAlignment = Alignment.Center,
    ) {
        Icon(if (stopping) AgentIcons.stop else AgentIcons.send, contentDescription = null, tint = glyph, modifier = Modifier.size(22.dp))
    }
}
