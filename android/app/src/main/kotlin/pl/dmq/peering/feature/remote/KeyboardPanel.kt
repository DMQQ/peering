package pl.dmq.peering.feature.remote

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Surface
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.peeringShapes

/** The keys a phone keyboard lacks, above the bottom bar: Esc, Tab, arrows and F-keys, then the latching modifiers. */
@Composable
fun KeyboardPanel(
    latches: Map<StickyModifier, ModifierLatch>,
    onFunctionKey: (FunctionKey) -> Unit,
    onEditingKey: (EditingKey) -> Unit,
    onModifier: (StickyModifier) -> Unit,
    modifier: Modifier = Modifier,
) {
    Surface(
        modifier = modifier.fillMaxWidth(),
        shape = peeringShapes.large,
        color = PeeringColors.containerHigh,
        shadowElevation = 6.dp,
    ) {
        Column(
            modifier = Modifier.padding(vertical = 8.dp, horizontal = 4.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            FunctionKeyRow(onKey = onFunctionKey, onEditingKey = onEditingKey)
            ModifierBar(latches = latches, onTap = onModifier)
        }
    }
}
