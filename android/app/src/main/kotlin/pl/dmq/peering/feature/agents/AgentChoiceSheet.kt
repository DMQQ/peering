package pl.dmq.peering.feature.agents

import androidx.compose.runtime.Composable
import androidx.compose.ui.res.stringResource
import pl.dmq.peering.R
import pl.dmq.peering.ui.kit.ChoiceRow
import pl.dmq.peering.ui.kit.PeeringSheet

@Composable
fun AgentChoiceSheet(
    agents: List<AgentOption>,
    onChoose: (String) -> Unit,
    onDismiss: () -> Unit,
) {
    PeeringSheet(onDismiss = onDismiss, title = stringResource(R.string.agents_choose_agent_title)) {
        agents.forEach { agent ->
            val brand = AgentBrand.of(agent.id)
            ChoiceRow(
                icon = brand.icon(),
                title = agent.name,
                description = stringResource(brand.taglineRes()),
                onClick = { onChoose(agent.id) },
            )
        }
    }
}
