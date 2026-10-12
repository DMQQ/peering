package pl.dmq.peering.feature.terminal

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import pl.dmq.peering.ui.theme.KeyShape
import pl.dmq.peering.ui.theme.peeringShapes
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import pl.dmq.peering.R
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.kit.PeeringMenu
import pl.dmq.peering.ui.kit.PeeringMenuItem
import pl.dmq.peering.ui.kit.PeeringSheet
import pl.dmq.peering.ui.kit.tappable
import pl.dmq.peering.ui.theme.PeeringColors

private val outline = Color.White.copy(alpha = 0.14f)
private val cardShape get() = peeringShapes.extraSmall

/** What the sheet behind the deck's ellipsis reads and does. */
class AllKeysActions(
    val commands: List<QuickCommand>,
    val textSize: TerminalTextSize,
    val send: (String) -> Unit,
    val run: (QuickCommand) -> Unit,
    val remove: (QuickCommand) -> Unit,
    val edit: () -> Unit,
    val onTextSize: (TerminalTextSize) -> Unit,
)

/** Every key the deck leaves out, grouped by what it does and named in words, since a bare chord says little. */
@Composable
fun TerminalAllKeys(actions: AllKeysActions, onDismiss: () -> Unit) {
    PeeringSheet(onDismiss = onDismiss, scrollable = true, containerColor = PeeringColors.backdrop, partiallyExpandable = true) {
        Column(Modifier.padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(22.dp)) {
            QuickCommandsGrid(actions, onDismiss)
            TerminalKeySpecs.groups.forEach { group -> KeyGroup(group, actions.send) }
            TextSizeRow(actions)
        }
    }
}

@Composable
private fun GroupLabel(text: String) {
    Text(text, style = MaterialTheme.typography.labelLarge.copy(fontWeight = FontWeight.SemiBold), color = PeeringColors.muted)
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun KeyGroup(group: TerminalKeyGroup, send: (String) -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        GroupLabel(stringResource(group.title))
        FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp), maxItemsInEachRow = 2) {
            group.keys.forEach { key ->
                Row(
                    Modifier.weight(1f).clip(cardShape).border(1.dp, outline, cardShape).tappable({ send(key.bytes) }).padding(8.dp),
                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Box(
                        Modifier.widthIn(min = 40.dp).background(Color.White.copy(alpha = 0.1f), KeyShape).padding(vertical = 6.dp, horizontal = 4.dp),
                        contentAlignment = Alignment.Center,
                    ) {
                        Text(key.title, color = PeeringColors.ink, fontSize = 13.sp, fontFamily = FontFamily.Monospace, fontWeight = FontWeight.SemiBold)
                    }
                    Text(
                        stringResource(key.label),
                        style = MaterialTheme.typography.bodySmall,
                        color = Color.White.copy(alpha = 0.75f),
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }
            if (group.keys.size % 2 == 1) Spacer(Modifier.weight(1f))
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun QuickCommandsGrid(actions: AllKeysActions, onDismiss: () -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        GroupLabel(stringResource(R.string.terminal_quick_commands))
        FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp), maxItemsInEachRow = 2) {
            actions.commands.forEach { command ->
                QuickChip(command, Modifier.weight(1f), onRun = {
                    onDismiss()
                    actions.run(command)
                }, onDelete = { actions.remove(command) })
            }
            AddOrEditChip(actions.commands.isEmpty(), Modifier.weight(1f)) {
                onDismiss()
                actions.edit()
            }
            if ((actions.commands.size + 1) % 2 == 1) Spacer(Modifier.weight(1f))
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun QuickChip(command: QuickCommand, modifier: Modifier, onRun: () -> Unit, onDelete: () -> Unit) {
    var menuOpen by remember { mutableStateOf(false) }
    Box(modifier) {
        Box(
            Modifier.fillMaxWidth().height(40.dp).clip(cardShape).border(1.dp, outline, cardShape)
                .combinedClickable(onClick = onRun, onLongClick = { menuOpen = true }),
            contentAlignment = Alignment.Center,
        ) {
            Text(command.displayTitle, color = PeeringColors.ink, fontSize = 13.sp, fontFamily = FontFamily.Monospace, fontWeight = FontWeight.Medium, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(horizontal = 8.dp))
        }
        PeeringMenu(expanded = menuOpen, onDismiss = { menuOpen = false }) {
            PeeringMenuItem(stringResource(R.string.terminal_quick_delete), icon = AppIcons.delete, destructive = true, onClick = {
                menuOpen = false
                onDelete()
            })
        }
    }
}

/** Drawn even when nothing is saved, so the feature can be found. */
@Composable
private fun AddOrEditChip(isEmpty: Boolean, modifier: Modifier, onClick: () -> Unit) {
    val dash = PathEffect.dashPathEffect(floatArrayOf(10f, 8f))
    Row(
        modifier.height(40.dp).clip(cardShape).tappable(onClick)
            .drawBehind { drawRoundRect(outline, cornerRadius = CornerRadius(12.dp.toPx()), style = Stroke(1.dp.toPx(), pathEffect = dash)) },
        horizontalArrangement = Arrangement.Center,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(if (isEmpty) TerminalGlyphs.add else AppIcons.tune, null, tint = PeeringColors.ink, modifier = Modifier.size(16.dp))
        Spacer(Modifier.width(6.dp))
        Text(stringResource(if (isEmpty) R.string.terminal_quick_add else R.string.terminal_quick_edit), color = PeeringColors.ink, fontSize = 13.sp, fontWeight = FontWeight.Medium)
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun TextSizeRow(actions: AllKeysActions) {
    Column(Modifier.padding(bottom = 8.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        GroupLabel(stringResource(R.string.terminal_text_size))
        SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
            val sizes = TerminalTextSize.entries
            sizes.forEachIndexed { index, size ->
                SegmentedButton(
                    selected = size == actions.textSize,
                    onClick = { actions.onTextSize(size) },
                    shape = SegmentedButtonDefaults.itemShape(index, sizes.size),
                    colors = SegmentedButtonDefaults.colors(
                        activeContainerColor = PeeringColors.selectedIndicator,
                        activeContentColor = PeeringColors.ink,
                        inactiveContainerColor = Color.Transparent,
                        inactiveContentColor = PeeringColors.ink,
                        activeBorderColor = PeeringColors.accent,
                        inactiveBorderColor = PeeringColors.outline,
                    ),
                ) { Text(stringResource(size.label), maxLines = 1) }
            }
        }
    }
}
