package pl.dmq.peering.feature.agents

import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.clickable
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import pl.dmq.peering.R
import pl.dmq.peering.ui.kit.PeeringMenu
import pl.dmq.peering.ui.kit.PeeringMenuDivider
import pl.dmq.peering.ui.kit.PeeringMenuItem
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText
import pl.dmq.peering.ui.theme.PillShape
import pl.dmq.peering.wire.AgentPermissionMode

/** The chat's permission mode as an outlined chip that names the current mode; the menu lists what the agent supports. */
@Composable
fun PermissionChip(
    current: AgentPermissionMode?,
    modes: List<AgentPermissionMode>,
    agentID: String?,
    onPick: (AgentPermissionMode) -> Unit,
) {
    var open by remember { mutableStateOf(false) }
    val shown = current ?: modes.firstOrNull() ?: AgentPermissionMode.MANUAL
    Box {
        OptionChip(stringResource(permissionTitle(shown)), permissionIcon(shown)) { open = true }
        PeeringMenu(open, { open = false }) {
            modes.forEach { mode ->
                PeeringMenuItem(
                    title = stringResource(permissionTitle(mode)),
                    supporting = stringResource(permissionDetail(PermissionModeCopy.detail(mode, agentID))),
                    icon = permissionIcon(mode),
                    selected = mode == current,
                    onClick = {
                        open = false
                        onPick(mode)
                    },
                )
            }
        }
    }
}

/** The chat's model as an outlined chip: Default, what the computer offers, and a typed name. */
@Composable
fun ModelChip(
    current: String?,
    choices: List<String>,
    onPick: (String?) -> Unit,
    onCustom: () -> Unit,
) {
    var open by remember { mutableStateOf(false) }
    Box {
        OptionChip(current ?: stringResource(R.string.agents_model_default), AgentIcons.model) { open = true }
        PeeringMenu(open, { open = false }) {
            PeeringMenuItem(
                title = stringResource(R.string.agents_model_default),
                selected = current == null,
                onClick = {
                    open = false
                    onPick(null)
                },
            )
            choices.forEach { model ->
                PeeringMenuItem(
                    title = model,
                    selected = model == current,
                    onClick = {
                        open = false
                        onPick(model)
                    },
                )
            }
            PeeringMenuDivider()
            PeeringMenuItem(
                title = stringResource(R.string.agents_model_custom),
                onClick = {
                    open = false
                    onCustom()
                },
            )
        }
    }
}

@Composable
private fun OptionChip(title: String, icon: ImageVector, onClick: () -> Unit) {
    Row(
        modifier = Modifier
            .heightIn(min = 32.dp)
            .clip(PillShape)
            .border(1.dp, PeeringColors.ink.copy(alpha = 0.16f), PillShape)
            .clickable(role = Role.Button, onClick = onClick)
            .padding(horizontal = 11.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Icon(icon, contentDescription = null, tint = PeeringColors.ink.copy(alpha = 0.85f), modifier = Modifier.size(13.dp))
        Text(
            title,
            style = PeeringText.caption.copy(fontSize = 12.5.sp, fontWeight = FontWeight.Medium),
            color = PeeringColors.ink.copy(alpha = 0.85f),
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        Icon(AgentIcons.chooser, contentDescription = null, tint = PeeringColors.ink.copy(alpha = 0.4f), modifier = Modifier.size(10.dp))
    }
}

private fun permissionIcon(mode: AgentPermissionMode): ImageVector = when (mode) {
    AgentPermissionMode.MANUAL -> AgentIcons.hand
    AgentPermissionMode.ACCEPT_EDITS -> AgentIcons.acceptEdits
    AgentPermissionMode.PLAN -> AgentIcons.review
    AgentPermissionMode.AUTO -> AgentIcons.auto
}

private fun permissionTitle(mode: AgentPermissionMode): Int = when (mode) {
    AgentPermissionMode.MANUAL -> R.string.permission_manual
    AgentPermissionMode.ACCEPT_EDITS -> R.string.permission_accept_edits
    AgentPermissionMode.PLAN -> R.string.permission_plan
    AgentPermissionMode.AUTO -> R.string.permission_auto
}

private fun permissionDetail(detail: PermissionDetail): Int = when (detail) {
    PermissionDetail.ASKS_BEFORE_ACTING -> R.string.permission_detail_asks
    PermissionDetail.EDITS_WITHOUT_ASKING -> R.string.permission_detail_edits
    PermissionDetail.WORKS_INSIDE_FOLDER -> R.string.permission_detail_folder
    PermissionDetail.PLANS_ONLY -> R.string.permission_detail_plan
    PermissionDetail.REVIEWER_CHECKS -> R.string.permission_detail_reviewer
    PermissionDetail.NEVER_ASKS -> R.string.permission_detail_never
}
