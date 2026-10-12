package pl.dmq.peering.feature.agents

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.session.agent.PendingApproval
import pl.dmq.peering.ui.theme.OutlinedPanel
import pl.dmq.peering.ui.theme.PeeringColors

/** An ask the Mac is waiting on. The answer buttons are the only way out of it from the phone. */
@Composable
fun ApprovalCard(
    port: AgentsPort,
    sessionID: String,
    approval: PendingApproval,
    modifier: Modifier = Modifier,
) {
    val scope = rememberCoroutineScope()
    val presenter = remember(sessionID, approval.approvalID) {
        ApprovalPresenter(port, sessionID, approval, scope)
    }
    val ui by presenter.ui.collectAsState()
    OutlinedPanel(modifier = modifier.fillMaxWidth()) {
        Text(ui.title, style = MaterialTheme.typography.titleMedium, color = PeeringColors.ink, maxLines = 1)
        Text(subtitleText(ui), style = MaterialTheme.typography.bodySmall, color = PeeringColors.muted)
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .padding(top = 12.dp)
                .background(PeeringColors.surface, RoundedCornerShape(12.dp))
                .border(1.dp, PeeringColors.hairline, RoundedCornerShape(12.dp))
                .padding(12.dp),
        ) {
            SelectionContainer {
                Text(
                    ui.body,
                    style = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace),
                    color = PeeringColors.ink,
                )
            }
        }
        ui.reason?.let {
            Text(it, style = MaterialTheme.typography.bodySmall, color = PeeringColors.faint, modifier = Modifier.padding(top = 8.dp))
        }
        ui.risk?.let {
            Text(riskText(it), style = MaterialTheme.typography.labelMedium, color = PeeringColors.caution, modifier = Modifier.padding(top = 8.dp))
        }
        Column(modifier = Modifier.padding(top = 14.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            if (ui.showsAllowAndDeny) {
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp), modifier = Modifier.fillMaxWidth()) {
                    OutlinedButton(onClick = presenter::deny, enabled = ui.enabled, modifier = Modifier.weight(1f)) {
                        Text(stringResource(R.string.approval_deny))
                    }
                    Button(
                        onClick = presenter::allow,
                        enabled = ui.enabled,
                        modifier = Modifier.weight(1f),
                        colors = ButtonDefaults.buttonColors(containerColor = PeeringColors.ink, contentColor = PeeringColors.onInk),
                    ) {
                        Text(stringResource(R.string.approval_allow))
                    }
                }
            } else {
                ui.options.forEach { option ->
                    OutlinedPanel(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clickable(enabled = ui.enabled) { presenter.choose(option.label) },
                    ) {
                        Text(option.label, style = MaterialTheme.typography.titleSmall, color = PeeringColors.ink)
                        option.detail?.let {
                            Text(it, style = MaterialTheme.typography.bodySmall, color = PeeringColors.muted)
                        }
                    }
                }
            }
            if (ui.canGoBack) {
                TextButton(onClick = presenter::back, enabled = ui.enabled, modifier = Modifier.align(Alignment.CenterHorizontally)) {
                    Text(stringResource(R.string.approval_back), color = PeeringColors.muted)
                }
            }
        }
    }
}

@Composable
private fun subtitleText(ui: ApprovalUi): String = when (ui.subtitle) {
    ApprovalSubtitle.WANTS_TO_RUN -> stringResource(R.string.approval_wants_to_run)
    ApprovalSubtitle.ASKS_QUESTION -> stringResource(R.string.approval_asks_question)
    ApprovalSubtitle.QUESTION_STEP -> stringResource(R.string.approval_question_step, ui.stepNumber, ui.stepCount)
}

@Composable
private fun riskText(risk: ApprovalRisk): String = stringResource(
    when (risk) {
        ApprovalRisk.RUNS_COMMAND -> R.string.approval_risk_command
        ApprovalRisk.CHANGES_FILES -> R.string.approval_risk_change
        ApprovalRisk.READS_FILES -> R.string.approval_risk_read
        ApprovalRisk.FETCHES_WEB -> R.string.approval_risk_web
        ApprovalRisk.USES_TOOL -> R.string.approval_risk_tool
    },
)
