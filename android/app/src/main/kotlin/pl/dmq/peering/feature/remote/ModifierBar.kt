package pl.dmq.peering.feature.remote

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R

/** Latching modifier keys above the soft keyboard. */
@Composable
fun ModifierBar(
    latches: Map<StickyModifier, ModifierLatch>,
    onTap: (StickyModifier) -> Unit,
    modifier: Modifier = Modifier,
) {
    Row(modifier = modifier, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        StickyModifier.entries.forEach { key ->
            val latch = latches[key] ?: ModifierLatch.OFF
            KeyCap(
                label = stringResource(key.labelRes()),
                selected = latch != ModifierLatch.OFF,
                outlinedInAccent = latch == ModifierLatch.LOCKED,
                onClick = { onTap(key) },
                stateText = when (latch) {
                    ModifierLatch.OFF -> null
                    ModifierLatch.LATCHED -> stringResource(R.string.remote_modifier_latched)
                    ModifierLatch.LOCKED -> stringResource(R.string.remote_modifier_locked)
                },
            )
        }
    }
}

private fun StickyModifier.labelRes(): Int = when (this) {
    StickyModifier.SHIFT -> R.string.remote_modifier_shift
    StickyModifier.CONTROL -> R.string.remote_modifier_control
    StickyModifier.OPTION -> R.string.remote_modifier_option
    StickyModifier.COMMAND -> R.string.remote_modifier_command
}
