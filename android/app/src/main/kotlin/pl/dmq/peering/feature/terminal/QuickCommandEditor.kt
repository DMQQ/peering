package pl.dmq.peering.feature.terminal

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.kit.ControlIcon
import pl.dmq.peering.ui.kit.ControlsCard
import pl.dmq.peering.ui.kit.ControlsDivider
import pl.dmq.peering.ui.kit.PeeringListItem
import pl.dmq.peering.ui.kit.PeeringMenu
import pl.dmq.peering.ui.kit.PeeringMenuItem
import pl.dmq.peering.ui.kit.PeeringSheet
import pl.dmq.peering.ui.kit.PeeringTextField
import pl.dmq.peering.ui.kit.PrimaryButton
import pl.dmq.peering.ui.theme.EmptyState
import pl.dmq.peering.ui.theme.PeeringColors

/** The saved commands, with a sheet to add one or change one. The same two sheets the iPhone has. */
@Composable
fun QuickCommandEditor(commands: List<QuickCommand>, onSave: (QuickCommand) -> Unit, onDelete: (QuickCommand) -> Unit, onDismiss: () -> Unit) {
    var editing by remember { mutableStateOf<QuickCommand?>(null) }
    var adding by remember { mutableStateOf(false) }
    PeeringSheet(onDismiss = onDismiss, title = stringResource(R.string.terminal_quick_title), scrollable = true) {
        Column(Modifier.padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(18.dp)) {
            if (commands.isEmpty()) {
                EmptyState(
                    icon = TerminalGlyphs.terminal,
                    title = stringResource(R.string.terminal_quick_empty_title),
                    body = stringResource(R.string.terminal_quick_empty_body),
                )
            } else {
                ControlsCard(stringResource(R.string.terminal_quick_saved)) {
                    commands.forEachIndexed { index, command ->
                        SavedRow(command, onEdit = { editing = command }, onDelete = { onDelete(command) })
                        if (index < commands.lastIndex) ControlsDivider()
                    }
                }
            }
            PrimaryButton(stringResource(R.string.terminal_quick_add_command), onClick = { adding = true })
        }
    }
    if (adding) CommandSheet(null, onSave, onDismiss = { adding = false })
    editing?.let { CommandSheet(it, onSave, onDismiss = { editing = null }) }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun SavedRow(command: QuickCommand, onEdit: () -> Unit, onDelete: () -> Unit) {
    var menuOpen by remember { mutableStateOf(false) }
    Box {
        PeeringListItem(
            headline = command.displayTitle,
            supporting = command.command,
            bleed = false,
            modifier = Modifier.combinedClickable(onClick = onEdit, onLongClick = { menuOpen = true }),
            leading = { ControlIcon(TerminalGlyphs.terminal) },
            trailing = { Icon(AppIcons.chevronRight, null, tint = PeeringColors.tertiary) },
        )
        PeeringMenu(expanded = menuOpen, onDismiss = { menuOpen = false }) {
            PeeringMenuItem(stringResource(R.string.terminal_quick_delete), icon = AppIcons.delete, destructive = true, onClick = {
                menuOpen = false
                onDelete()
            })
        }
    }
}

@Composable
private fun CommandSheet(existing: QuickCommand?, onSave: (QuickCommand) -> Unit, onDismiss: () -> Unit) {
    var title by remember { mutableStateOf(existing?.title.orEmpty()) }
    var line by remember { mutableStateOf(existing?.command.orEmpty()) }
    val canSave = line.isNotBlank()
    PeeringSheet(
        onDismiss = onDismiss,
        title = stringResource(if (existing == null) R.string.terminal_quick_new_title else R.string.terminal_quick_edit_title),
        scrollable = true,
    ) {
        Column(Modifier.padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(18.dp)) {
            ControlsCard(stringResource(R.string.terminal_quick_command_label), footer = stringResource(R.string.terminal_quick_footer)) {
                PeeringTextField(
                    value = title,
                    onValueChange = { title = it },
                    label = stringResource(R.string.terminal_quick_name_optional),
                    modifier = Modifier.fillMaxWidth(),
                    keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.None, autoCorrectEnabled = false),
                )
                PeeringTextField(
                    value = line,
                    onValueChange = { line = it },
                    label = stringResource(R.string.terminal_quick_command_hint),
                    modifier = Modifier.fillMaxWidth(),
                    keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.None, autoCorrectEnabled = false),
                    monospaced = true,
                )
            }
            PrimaryButton(
                stringResource(if (existing == null) R.string.terminal_quick_add_submit else R.string.terminal_quick_save_submit),
                enabled = canSave,
                onClick = {
                    onSave((existing ?: QuickCommand(title = "", command = "")).copy(title = title.trim(), command = line.trim()))
                    onDismiss()
                },
            )
        }
    }
}
