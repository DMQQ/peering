package pl.dmq.peering.feature.remote

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import java.util.UUID
import pl.dmq.peering.R
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.kit.ControlPicker
import pl.dmq.peering.ui.kit.ControlToggle
import pl.dmq.peering.ui.kit.ControlsCard
import pl.dmq.peering.ui.kit.ControlsDivider
import pl.dmq.peering.ui.kit.PeeringSheet
import pl.dmq.peering.ui.kit.PeeringTextField
import pl.dmq.peering.ui.kit.PrimaryButton
import pl.dmq.peering.ui.kit.SessionIcons
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText
import pl.dmq.peering.wire.Modifiers

/** The macros: the ones added, each with a way to delete it, the built in ones, and a form to add another. */
@Composable
fun MacroEditorSheet(
    custom: List<Macro>,
    onAdd: (Macro) -> Unit,
    onRemove: (String) -> Unit,
    onDismiss: () -> Unit,
) {
    PeeringSheet(onDismiss = onDismiss, title = stringResource(R.string.macros_title), scrollable = true) {
        Column(Modifier.padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            ControlsCard(stringResource(R.string.macros_custom)) {
                if (custom.isEmpty()) {
                    Text(stringResource(R.string.macros_custom_empty), style = PeeringText.subheadline, color = PeeringColors.muted)
                }
                custom.forEach { macro -> CustomRow(macro) { onRemove(macro.id) } }
            }
            NewMacroForm(onAdd)
            ControlsCard(stringResource(R.string.macros_builtin)) {
                Macros.defaults.forEachIndexed { index, macro ->
                    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                        Text(macro.title, style = PeeringText.subheadline, color = PeeringColors.ink, modifier = Modifier.weight(1f))
                        Text(stringResource(R.string.macros_builtin_tag), style = PeeringText.caption, color = PeeringColors.tertiary)
                    }
                    if (index < Macros.defaults.lastIndex) ControlsDivider()
                }
            }
        }
    }
}

@Composable
private fun CustomRow(macro: Macro, onRemove: () -> Unit) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Text(macro.title, style = PeeringText.subheadlineSemibold, color = PeeringColors.ink, modifier = Modifier.weight(1f))
        IconButton(onClick = onRemove) {
            Icon(AppIcons.delete, contentDescription = stringResource(R.string.macros_delete, macro.title), tint = PeeringColors.danger)
        }
    }
}

@Composable
private fun NewMacroForm(onAdd: (Macro) -> Unit) {
    var label by rememberSaveable { mutableStateOf("") }
    var keyId by rememberSaveable { mutableStateOf(MacroKeys.popular.first().id) }
    var modifiers by rememberSaveable { mutableLongStateOf(0L) }
    val key = MacroKeys.popular.first { it.id == keyId }
    val title = label.ifBlank { Macros.autoTitle(key, modifiers) }
    ControlsCard(stringResource(R.string.macros_new)) {
        PeeringTextField(label, { label = it }, stringResource(R.string.macros_label_hint), Modifier.fillMaxWidth())
        ControlPicker(
            title = stringResource(R.string.macros_key),
            icon = SessionIcons.keyboard,
            selected = key,
            options = MacroKeys.popular,
            optionTitle = { it.label },
            onSelect = { keyId = it.id },
        )
        ControlsDivider()
        ModifierSwitch(R.string.remote_modifier_command, Modifiers.COMMAND, modifiers) { modifiers = it }
        ModifierSwitch(R.string.remote_modifier_option, Modifiers.OPTION, modifiers) { modifiers = it }
        ModifierSwitch(R.string.remote_modifier_control, Modifiers.CONTROL, modifiers) { modifiers = it }
        ModifierSwitch(R.string.remote_modifier_shift, Modifiers.SHIFT, modifiers) { modifiers = it }
        ControlsDivider()
        Row(Modifier.fillMaxWidth()) {
            Text(stringResource(R.string.macros_preview), style = PeeringText.subheadline, color = PeeringColors.muted, modifier = Modifier.weight(1f))
            Text(title, style = PeeringText.subheadlineSemibold, color = PeeringColors.ink)
        }
        PrimaryButton(stringResource(R.string.macros_add), {
            onAdd(Macro(UUID.randomUUID().toString(), title, key.keyCode, modifiers))
            label = ""
            modifiers = 0L
        })
    }
}

@Composable
private fun ModifierSwitch(nameRes: Int, bit: Long, modifiers: Long, onChange: (Long) -> Unit) {
    ControlToggle(
        title = stringResource(nameRes),
        icon = SessionIcons.key,
        checked = modifiers and bit != 0L,
        onCheckedChange = { on -> onChange(if (on) modifiers or bit else modifiers and bit.inv()) },
    )
}
