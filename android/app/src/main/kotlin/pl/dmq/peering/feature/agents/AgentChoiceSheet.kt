package pl.dmq.peering.feature.agents

import androidx.compose.material3.Icon
import androidx.compose.runtime.Composable
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import pl.dmq.peering.R
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.kit.PeeringListItem
import pl.dmq.peering.ui.kit.PeeringSheet

@Composable
fun AgentChoiceSheet(
    agents: List<AgentOption>,
    onChoose: (String) -> Unit,
    onDismiss: () -> Unit,
) {
    PeeringSheet(onDismiss = onDismiss, title = stringResource(R.string.agents_choose_agent_title)) {
        agents.forEach { agent ->
            PeeringListItem(
                headline = agent.name,
                onClick = { onChoose(agent.id) },
                role = Role.Button,
                bleed = false,
                leading = { Icon(AppIcons.sparkles, contentDescription = null) },
            )
        }
    }
}
