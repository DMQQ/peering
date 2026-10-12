package pl.dmq.peering.feature.terminal

import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material3.AssistChip
import androidx.compose.material3.AssistChipDefaults
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FilterChipDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PillShape

/** Escape, Tab, the Ctrl and Alt latches, the arrows and the two characters a phone keyboard buries. */
@Composable
fun ExtraKeysRow(keyboard: TerminalKeyboard, modifier: Modifier = Modifier) {
    Row(
        modifier = modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal = 8.dp, vertical = 4.dp),
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        KeyChip(stringResource(R.string.terminal_key_esc)) { keyboard.press(ExtraKey.ESCAPE) }
        KeyChip(stringResource(R.string.terminal_key_tab)) { keyboard.press(ExtraKey.TAB) }
        LatchChip(stringResource(R.string.terminal_key_ctrl), keyboard.ctrl, keyboard::toggleCtrl)
        LatchChip(stringResource(R.string.terminal_key_alt), keyboard.alt, keyboard::toggleAlt)
        ArrowChip(TerminalGlyphs.up, stringResource(R.string.terminal_key_up)) { keyboard.press(ExtraKey.UP) }
        ArrowChip(TerminalGlyphs.down, stringResource(R.string.terminal_key_down)) { keyboard.press(ExtraKey.DOWN) }
        ArrowChip(TerminalGlyphs.left, stringResource(R.string.terminal_key_left)) { keyboard.press(ExtraKey.LEFT) }
        ArrowChip(TerminalGlyphs.right, stringResource(R.string.terminal_key_right)) { keyboard.press(ExtraKey.RIGHT) }
        KeyChip("|", stringResource(R.string.terminal_key_pipe)) { keyboard.press(ExtraKey.PIPE) }
        KeyChip("~", stringResource(R.string.terminal_key_tilde)) { keyboard.press(ExtraKey.TILDE) }
    }
}

@Composable
private fun KeyChip(label: String, description: String = label, onClick: () -> Unit) {
    AssistChip(
        onClick = onClick,
        label = { Text(label) },
        modifier = Modifier.semantics { contentDescription = description },
        shape = PillShape,
        colors = AssistChipDefaults.assistChipColors(containerColor = PeeringColors.containerHigh, labelColor = PeeringColors.ink),
        border = AssistChipDefaults.assistChipBorder(enabled = true, borderColor = PeeringColors.hairline),
    )
}

@Composable
private fun ArrowChip(icon: ImageVector, description: String, onClick: () -> Unit) {
    AssistChip(
        onClick = onClick,
        label = { Icon(icon, contentDescription = description) },
        shape = PillShape,
        colors = AssistChipDefaults.assistChipColors(containerColor = PeeringColors.containerHigh, labelColor = PeeringColors.ink),
        border = AssistChipDefaults.assistChipBorder(enabled = true, borderColor = PeeringColors.hairline),
    )
}

@Composable
private fun LatchChip(label: String, latched: Boolean, onClick: () -> Unit) {
    FilterChip(
        selected = latched,
        onClick = onClick,
        label = { Text(label) },
        shape = PillShape,
        colors = FilterChipDefaults.filterChipColors(
            containerColor = PeeringColors.containerHigh,
            labelColor = PeeringColors.ink,
            selectedContainerColor = PeeringColors.selectedIndicator,
            selectedLabelColor = PeeringColors.ink,
        ),
        border = FilterChipDefaults.filterChipBorder(
            enabled = true,
            selected = latched,
            borderColor = PeeringColors.hairline,
            selectedBorderColor = PeeringColors.accent,
        ),
    )
}
