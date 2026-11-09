package pl.dmq.peering.feature.agents.routines

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.feature.agents.AgentCatalog
import pl.dmq.peering.ui.kit.QuietButton
import pl.dmq.peering.ui.kit.hubCardSurface
import pl.dmq.peering.ui.kit.tappable
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText
import pl.dmq.peering.ui.theme.peeringShapes
import pl.dmq.peering.wire.AgentRoutine
import pl.dmq.peering.wire.AgentRoutineOutcome

/** One routine: what it is, when it runs, how its last run went, and a way to run it now. */
@Composable
internal fun RoutineRow(routine: AgentRoutine, onEdit: () -> Unit, onRunNow: () -> Unit, modifier: Modifier = Modifier) {
    val isRunning = routine.lastRun?.outcome == AgentRoutineOutcome.RUNNING
    Row(
        modifier.fillMaxWidth().hubCardSurface(peeringShapes.large).padding(14.dp),
        horizontalArrangement = Arrangement.spacedBy(11.dp),
        verticalAlignment = Alignment.Top,
    ) {
        Column(Modifier.weight(1f).tappable(onEdit), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(routine.name, style = PeeringText.subheadlineSemibold, color = PeeringColors.ink)
            val summary = listOfNotNull(AgentCatalog.name(routine.agentID), scheduleText(routine.schedule), nextRunText(routine))
            Text(summary.joinToString(" · "), style = PeeringText.caption, color = PeeringColors.muted)
            Text(lastRunText(routine.lastRun), style = PeeringText.caption, color = statusTint(routine.lastRun?.outcome))
        }
        QuietButton(onClick = { if (!isRunning) onRunNow() }) {
            Text(
                stringResource(if (isRunning) R.string.routines_running else R.string.routines_run_now),
                style = PeeringText.captionSemibold,
                color = if (isRunning) PeeringColors.faint else PeeringColors.ink,
            )
        }
    }
}

private fun statusTint(outcome: AgentRoutineOutcome?): Color = when (outcome) {
    AgentRoutineOutcome.FAILED, AgentRoutineOutcome.SKIPPED -> PeeringColors.danger
    AgentRoutineOutcome.STOPPED -> PeeringColors.caution
    else -> PeeringColors.muted
}
