package pl.dmq.peering.feature.agents

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import pl.dmq.peering.R
import pl.dmq.peering.ui.kit.PeeringTextField
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText
import pl.dmq.peering.ui.theme.PillShape
import pl.dmq.peering.wire.AgentPermissionMode

/** This chat's model and permissions as chips that say their current value, and the context meter at the far end. */
@Composable
fun OptionsBar(
    ui: ComposerUi,
    chip: ContextChip?,
    onPermission: (AgentPermissionMode) -> Unit,
    onModel: (String?) -> Unit,
    onShowUsage: () -> Unit,
    onCustomModel: () -> Unit,
    modifier: Modifier = Modifier,
) {
    if (ui.sessionID == null) return
    Row(
        modifier = modifier.fillMaxWidth().padding(start = 14.dp, end = 14.dp, top = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        if (ui.modelChoices.isNotEmpty()) {
            ModelChip(ui.model, ui.modelChoices, onModel, onCustom = onCustomModel)
        }
        if (ui.permissionModes.size > 1) {
            PermissionChip(ui.permissionMode, ui.permissionModes, ui.agentID, onPermission)
        }
        Box(Modifier.weight(1f), contentAlignment = Alignment.CenterEnd) {
            chip?.let { ContextBar(it, onShowUsage) }
        }
    }
}

/** How much of the context window is used ("70k / 1M") and the five-hour window beside it; it opens the usage sheet. */
@Composable
fun ContextBar(chip: ContextChip, onClick: () -> Unit) {
    BoxWithConstraints(Modifier.heightIn(min = 32.dp), contentAlignment = Alignment.CenterEnd) {
        val showsBar = maxWidth >= 150.dp
        val showsFiveHour = maxWidth >= 100.dp
        val tone = if (chip.nearlyFull) 0.9f else 0.55f
        Row(
            modifier = Modifier.clip(PillShape).clickable(role = Role.Button, onClick = onClick).padding(horizontal = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            val fraction = chip.contextFraction
            if (showsBar && fraction != null) Meter(fraction.toFloat(), chip.nearlyFull)
            chip.contextLabel?.let { Figure(it, tone) }
            if (showsFiveHour) chip.fiveHourPercent?.let { Figure("5h $it%", tone) }
        }
    }
}

@Composable
private fun Figure(text: String, tone: Float) {
    Text(text, style = PeeringText.caption.copy(fontSize = 11.5.sp, fontWeight = FontWeight.Medium), color = PeeringColors.ink.copy(alpha = tone), maxLines = 1)
}

@Composable
private fun Meter(fraction: Float, nearlyFull: Boolean) {
    Box(Modifier.size(width = 34.dp, height = 4.dp).clip(PillShape).background(PeeringColors.ink.copy(alpha = 0.14f))) {
        Box(
            Modifier
                .size(width = (34 * fraction.coerceIn(0f, 1f)).coerceAtLeast(4f).dp, height = 4.dp)
                .clip(PillShape)
                .background(PeeringColors.ink.copy(alpha = if (nearlyFull) 0.95f else 0.55f)),
        )
    }
}

@Composable
internal fun CustomModelDialog(initial: String, onUse: (String) -> Unit, onDismiss: () -> Unit) {
    var text by remember { mutableStateOf(initial) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.agents_model_title)) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text(stringResource(R.string.agents_model_message), style = PeeringText.footnote, color = PeeringColors.muted)
                PeeringTextField(text, { text = it }, label = stringResource(R.string.agents_model_name), monospaced = true)
            }
        },
        confirmButton = {
            TextButton(onClick = {
                onUse(text.trim())
                onDismiss()
            }) { Text(stringResource(R.string.agents_model_use), color = PeeringColors.accent) }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.agents_cancel), color = PeeringColors.accent) } },
        containerColor = PeeringColors.containerHigh,
        titleContentColor = PeeringColors.ink,
        textContentColor = PeeringColors.muted,
    )
}
