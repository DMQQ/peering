package pl.dmq.peering.feature.agents

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.ui.theme.PeeringColors

/** One chat: its title line, the conversation with any pending asks, and the composer under it. */
@Composable
fun ChatScreen(
    transcript: TranscriptPresenter,
    composer: ComposerPresenter,
    port: AgentsPort,
    title: String,
    directory: String,
    onBackToList: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(modifier = modifier.fillMaxSize()) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                stringResource(R.string.agents_back_to_list),
                style = MaterialTheme.typography.labelLarge,
                color = PeeringColors.muted,
                modifier = Modifier.clickable(onClick = onBackToList).padding(end = 12.dp),
            )
            Column(modifier = Modifier.weight(1f)) {
                Text(title, style = MaterialTheme.typography.titleMedium, color = PeeringColors.ink, maxLines = 1)
                Text(directory, style = MaterialTheme.typography.bodySmall, color = PeeringColors.muted, maxLines = 1)
            }
        }
        TranscriptList(presenter = transcript, port = port, modifier = Modifier.weight(1f))
        Composer(presenter = composer)
    }
}
