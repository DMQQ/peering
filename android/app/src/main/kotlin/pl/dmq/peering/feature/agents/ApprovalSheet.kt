package pl.dmq.peering.feature.agents

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import pl.dmq.peering.R
import pl.dmq.peering.session.agent.PendingApproval
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.kit.PeeringSheet
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText
import pl.dmq.peering.ui.theme.peeringShapes

/** What the agent is asking: a command to allow or deny, or questions with options. It opens by itself when the agent asks. */
@Composable
fun ApprovalSheet(port: AgentsPort, sessionID: String, approval: PendingApproval, onDismiss: () -> Unit) {
    val scope = rememberCoroutineScope()
    val presenter = remember(sessionID, approval.approvalID) { ApprovalPresenter(port, sessionID, approval, scope) }
    val ui by presenter.ui.collectAsState()
    PeeringSheet(onDismiss = onDismiss, scrollable = true) {
        Column(Modifier.padding(horizontal = 20.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Header(ui)
            if (ui.body.isNotBlank()) {
                SelectionContainer {
                    Text(
                        ui.body,
                        style = PeeringText.footnote.copy(fontSize = 13.sp, fontFamily = FontFamily.Monospace, lineHeight = 18.sp),
                        color = PeeringColors.ink.copy(alpha = 0.85f),
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(peeringShapes.extraSmall)
                            .background(PeeringColors.ink.copy(alpha = 0.06f))
                            .padding(12.dp),
                    )
                }
            }
            ui.reason?.let { Text(it, style = PeeringText.caption, color = PeeringColors.ink.copy(alpha = 0.55f)) }
            if (ui.showsAllowAndDeny) {
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    SideButton(stringResource(R.string.approval_deny), filled = false, enabled = ui.enabled, onClick = presenter::deny, modifier = Modifier.weight(1f))
                    SideButton(stringResource(R.string.approval_allow), filled = true, enabled = ui.enabled, onClick = presenter::allow, modifier = Modifier.weight(1f))
                }
            } else {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    ui.options.forEach { option -> OptionRow(option.label, option.detail, ui.stepNumber == ui.stepCount, ui.enabled) { presenter.choose(option.label) } }
                    if (ui.canGoBack) BackRow(ui.enabled, presenter::back)
                }
            }
        }
    }
}

@Composable
private fun Header(ui: ApprovalUi) {
    Row(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
        Box(
            Modifier.size(30.dp).clip(peeringShapes.extraSmall).background(PeeringColors.ink.copy(alpha = 0.1f)),
            contentAlignment = Alignment.Center,
        ) {
            Icon(if (ui.showsAllowAndDeny) AgentIcons.hand else AgentIcons.question, contentDescription = null, tint = PeeringColors.ink.copy(alpha = 0.9f), modifier = Modifier.size(16.dp))
        }
        Column(verticalArrangement = Arrangement.spacedBy(1.dp)) {
            Text(ui.title, style = PeeringText.subheadlineSemibold.copy(fontSize = 16.sp), color = PeeringColors.ink, maxLines = 1)
            Text(subtitleText(ui), style = PeeringText.caption, color = PeeringColors.muted)
        }
    }
}

@Composable
private fun SideButton(label: String, filled: Boolean, enabled: Boolean, onClick: () -> Unit, modifier: Modifier) {
    val shape = peeringShapes.small
    Box(
        modifier = modifier
            .heightIn(min = 46.dp)
            .clip(shape)
            .let { if (filled) it.background(PeeringColors.ink) else it.border(1.dp, PeeringColors.ink.copy(alpha = 0.22f), shape) }
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            label,
            style = PeeringText.subheadlineSemibold.copy(fontSize = 15.sp),
            color = if (filled) PeeringColors.onInk else PeeringColors.ink,
        )
    }
}

@Composable
private fun OptionRow(label: String, detail: String?, last: Boolean, enabled: Boolean, onClick: () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(peeringShapes.extraSmall)
            .border(1.dp, PeeringColors.ink.copy(alpha = 0.22f), peeringShapes.extraSmall)
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick)
            .padding(horizontal = 14.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(label, style = PeeringText.subheadlineMedium, color = PeeringColors.ink)
            detail?.takeIf { it.isNotEmpty() }?.let { Text(it, style = PeeringText.caption, color = PeeringColors.ink.copy(alpha = 0.55f)) }
        }
        Icon(if (last) AppIcons.check else AppIcons.chevronRight, contentDescription = null, tint = PeeringColors.tertiary, modifier = Modifier.size(16.dp))
    }
}

@Composable
private fun BackRow(enabled: Boolean, onClick: () -> Unit) {
    Text(
        stringResource(R.string.approval_back),
        style = PeeringText.subheadline.copy(fontWeight = FontWeight.Medium, fontSize = 14.sp, textAlign = TextAlign.Center),
        color = PeeringColors.ink.copy(alpha = 0.6f),
        modifier = Modifier.fillMaxWidth().heightIn(min = 40.dp).clickable(enabled = enabled, role = Role.Button, onClick = onClick).padding(top = 10.dp),
    )
}

@Composable
private fun subtitleText(ui: ApprovalUi): String = when (ui.subtitle) {
    ApprovalSubtitle.WANTS_TO_RUN -> stringResource(R.string.approval_wants_to_run)
    ApprovalSubtitle.ASKS_QUESTION -> stringResource(R.string.approval_asks_question)
    ApprovalSubtitle.QUESTION_STEP -> stringResource(R.string.approval_question_step, ui.stepNumber, ui.stepCount)
}
