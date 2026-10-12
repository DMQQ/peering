package pl.dmq.peering.feature.agents

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.session.agent.TranscriptRow
import pl.dmq.peering.ui.theme.OutlinedPanel
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.wire.AgentPlanStep
import pl.dmq.peering.wire.AgentPlanStepStatus

@Composable
fun PlanCard(steps: List<AgentPlanStep>) {
    OutlinedPanel(modifier = Modifier.fillMaxWidth()) {
        Text(stringResource(R.string.agents_plan_label), style = MaterialTheme.typography.labelMedium, color = PeeringColors.muted)
        Column(modifier = Modifier.padding(top = 10.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            steps.forEach { step -> PlanStepLine(step) }
        }
    }
}

@Composable
private fun PlanStepLine(step: AgentPlanStep) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        Box(
            modifier = Modifier
                .size(8.dp)
                .clip(CircleShape)
                .background(
                    when (step.status) {
                        AgentPlanStepStatus.COMPLETED -> PeeringColors.added
                        AgentPlanStepStatus.IN_PROGRESS -> PeeringColors.ink
                        AgentPlanStepStatus.PENDING -> PeeringColors.faint
                    },
                ),
        )
        Text(
            step.text,
            style = MaterialTheme.typography.bodyMedium,
            color = if (step.status == AgentPlanStepStatus.PENDING) PeeringColors.muted else PeeringColors.ink,
        )
    }
}

@Composable
fun SubagentStrip(row: TranscriptRow.Subagent) {
    val steps = row.transcript.rows.size
    val latest = row.transcript.rows.filterIsInstance<TranscriptRow.ToolCall>().lastOrNull()?.call?.title
    OutlinedPanel(modifier = Modifier.fillMaxWidth()) {
        Text(stringResource(R.string.agents_subagent_label), style = MaterialTheme.typography.labelMedium, color = PeeringColors.muted)
        Text(
            pluralStringResource(R.plurals.agents_subagent_steps, steps, steps),
            style = MaterialTheme.typography.bodySmall,
            color = PeeringColors.faint,
            modifier = Modifier.padding(top = 4.dp),
        )
        latest?.let {
            Text(it, style = MaterialTheme.typography.bodyMedium, color = PeeringColors.ink, modifier = Modifier.padding(top = 6.dp))
        }
    }
}
