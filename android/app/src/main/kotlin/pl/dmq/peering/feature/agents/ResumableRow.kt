package pl.dmq.peering.feature.agents

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.ui.theme.OutlinedPanel
import pl.dmq.peering.ui.theme.PeeringColors

/** A conversation started on the computer. Tapping continues it here, unless a terminal there may still have it open. */
@Composable
fun ResumableRow(card: ResumableCard, onContinue: () -> Unit, modifier: Modifier = Modifier) {
    val tap = if (card.openElsewhere) modifier else modifier.clickable(onClick = onContinue)
    OutlinedPanel(
        modifier = tap.fillMaxWidth().heightIn(min = 64.dp).clip(MaterialTheme.shapes.large),
        contentPadding = PaddingValues(horizontal = 16.dp, vertical = 12.dp),
    ) {
        Column {
            Text(card.title, style = MaterialTheme.typography.titleMedium, color = PeeringColors.ink, maxLines = 1)
            Text(
                "${card.agentName}  ·  ${card.directory}",
                style = MaterialTheme.typography.bodySmall,
                color = PeeringColors.muted,
                maxLines = 1,
            )
            if (card.openElsewhere) {
                Text(stringResource(R.string.agents_open_elsewhere), style = MaterialTheme.typography.labelMedium, color = PeeringColors.caution)
            } else {
                Text(lastActivityLabel(card.modifiedAtUnix), style = MaterialTheme.typography.labelMedium, color = PeeringColors.faint)
            }
        }
    }
}
