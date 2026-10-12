package pl.dmq.peering.feature.remote

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.ui.theme.PillShape

/** Latching modifier keys as Material filter chips: selected while held, with a lock mark once locked. */
@Composable
fun ModifierBar(
    latches: Map<StickyModifier, ModifierLatch>,
    onTap: (StickyModifier) -> Unit,
    modifier: Modifier = Modifier,
) {
    Row(modifier = modifier, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        StickyModifier.entries.forEach { key ->
            val latch = latches[key] ?: ModifierLatch.OFF
            val state = when (latch) {
                ModifierLatch.OFF -> null
                ModifierLatch.LATCHED -> stringResource(R.string.remote_modifier_latched)
                ModifierLatch.LOCKED -> stringResource(R.string.remote_modifier_locked)
            }
            FilterChip(
                selected = latch != ModifierLatch.OFF,
                onClick = { onTap(key) },
                label = {
                    Text(stringResource(key.labelRes()) + if (latch == ModifierLatch.LOCKED) " •" else "")
                },
                shape = PillShape,
                modifier = Modifier.semantics { if (state != null) stateDescription = state },
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
