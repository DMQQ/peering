package pl.dmq.peering.feature.agents

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
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.ui.theme.OutlinedPanel
import pl.dmq.peering.ui.theme.PeeringColors

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AgentChoiceSheet(
    agents: List<AgentOption>,
    onChoose: (String) -> Unit,
    onDismiss: () -> Unit,
) {
    ModalBottomSheet(onDismissRequest = onDismiss, containerColor = PeeringColors.backdrop) {
        Column(
            modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text(stringResource(R.string.agents_choose_agent_title), style = MaterialTheme.typography.headlineSmall)
            agents.forEach { agent ->
                OutlinedPanel(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clickable { onChoose(agent.id) },
                ) {
                    Text(agent.name, style = MaterialTheme.typography.titleMedium, color = PeeringColors.ink)
                }
            }
        }
    }
}
