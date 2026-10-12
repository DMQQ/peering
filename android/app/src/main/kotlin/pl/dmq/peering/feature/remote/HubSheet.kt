package pl.dmq.peering.feature.remote

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.ui.theme.OutlinedPanel
import pl.dmq.peering.ui.theme.PeeringColors

/** The session menu: one outlined row per entry the Mac supports. Disconnect is last and in the danger colour. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HubSheet(
    entries: List<HubEntry>,
    onSelect: (HubEntry) -> Unit,
    onDismiss: () -> Unit,
) {
    ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(
            modifier = Modifier.fillMaxWidth().padding(start = 16.dp, end = 16.dp, bottom = 24.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Text(
                text = stringResource(R.string.hub_title),
                style = MaterialTheme.typography.headlineSmall,
                color = PeeringColors.ink,
            )
            entries.forEach { entry ->
                OutlinedPanel(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(MaterialTheme.shapes.large)
                        .clickable(role = Role.Button) { onSelect(entry) },
                ) {
                    Text(
                        text = stringResource(entry.labelRes()),
                        style = MaterialTheme.typography.titleMedium,
                        color = if (entry == HubEntry.DISCONNECT) PeeringColors.danger else PeeringColors.ink,
                    )
                }
            }
        }
    }
}

private fun HubEntry.labelRes(): Int = when (this) {
    HubEntry.SOURCES -> R.string.hub_sources
    HubEntry.AGENTS -> R.string.hub_agents
    HubEntry.FILES -> R.string.hub_files
    HubEntry.QUALITY -> R.string.hub_quality
    HubEntry.DISCONNECT -> R.string.hub_disconnect
}
