package pl.dmq.peering.feature.remote

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import pl.dmq.peering.R
import pl.dmq.peering.ui.theme.ChipKeyShape
import pl.dmq.peering.ui.kit.tappable
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText

/** The order the phone draws the latching modifiers in, with the mark each carries. */
internal val MODIFIER_ORDER: List<StickyModifier> =
    listOf(StickyModifier.COMMAND, StickyModifier.SHIFT, StickyModifier.OPTION, StickyModifier.CONTROL)

internal fun StickyModifier.mark(): String = when (this) {
    StickyModifier.COMMAND -> "⌘"
    StickyModifier.SHIFT -> "⇧"
    StickyModifier.OPTION -> "⌥"
    StickyModifier.CONTROL -> "⌃"
}

/** The four latching modifiers as keys: held on the computer from the tap until the key after it, or until tapped again. */
@Composable
fun ModifierBar(
    latches: Map<StickyModifier, ModifierLatch>,
    onTap: (StickyModifier) -> Unit,
    modifier: Modifier = Modifier,
    large: Boolean = false,
) {
    Row(modifier, horizontalArrangement = Arrangement.spacedBy(if (large) 8.dp else 6.dp)) {
        MODIFIER_ORDER.forEach { key -> ModifierKey(key, latches[key] ?: ModifierLatch.OFF, onTap, large) }
    }
}

@Composable
private fun RowScope.ModifierKey(key: StickyModifier, latch: ModifierLatch, onTap: (StickyModifier) -> Unit, large: Boolean) {
    val state = when (latch) {
        ModifierLatch.OFF -> null
        ModifierLatch.LATCHED -> stringResource(R.string.remote_modifier_latched)
        ModifierLatch.LOCKED -> stringResource(R.string.remote_modifier_locked)
    }
    val name = stringResource(key.labelRes())
    val shape = ChipKeyShape
    Box(
        modifier = Modifier
            .then(if (large) Modifier.weight(1f).heightIn(min = 44.dp) else Modifier.size(width = 38.dp, height = 34.dp))
            .clip(shape)
            .background(if (latch == ModifierLatch.OFF) PeeringColors.ink.copy(alpha = 0.1f) else PeeringColors.accent)
            .tappable({ onTap(key) })
            .semantics {
                contentDescription = name
                if (state != null) stateDescription = state
            },
        contentAlignment = Alignment.Center,
    ) {
        Text(key.mark() + if (latch == ModifierLatch.LOCKED) "•" else "", style = PeeringText.body.copy(fontSize = 17.sp), color = PeeringColors.ink, maxLines = 1)
    }
}

private fun StickyModifier.labelRes(): Int = when (this) {
    StickyModifier.SHIFT -> R.string.remote_modifier_shift
    StickyModifier.CONTROL -> R.string.remote_modifier_control
    StickyModifier.OPTION -> R.string.remote_modifier_option
    StickyModifier.COMMAND -> R.string.remote_modifier_command
}

/** A row of modifiers that shares the width equally. */
@Composable
fun ModifierRow(
    latches: Map<StickyModifier, ModifierLatch>,
    onTap: (StickyModifier) -> Unit,
    modifier: Modifier = Modifier,
) {
    ModifierBar(latches, onTap, modifier.fillMaxWidth(), large = true)
}
