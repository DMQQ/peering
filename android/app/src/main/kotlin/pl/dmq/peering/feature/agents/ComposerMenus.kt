package pl.dmq.peering.feature.agents

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.res.stringResource
import pl.dmq.peering.R
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.wire.AgentPermissionMode

@Composable
fun PermissionModeMenu(
    current: AgentPermissionMode?,
    modes: List<AgentPermissionMode>,
    agentID: String?,
    onPick: (AgentPermissionMode) -> Unit,
) {
    var open by remember { mutableStateOf(false) }
    Box {
        TextButton(onClick = { open = true }, enabled = modes.isNotEmpty()) {
            Text(
                stringResource(current?.let(::permissionTitle) ?: R.string.permission_manual),
                style = MaterialTheme.typography.labelLarge,
                color = PeeringColors.ink,
            )
        }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            modes.forEach { mode ->
                DropdownMenuItem(
                    text = {
                        Column {
                            Text(stringResource(permissionTitle(mode)), style = MaterialTheme.typography.titleSmall)
                            Text(
                                stringResource(permissionDetail(PermissionModeCopy.detail(mode, agentID))),
                                style = MaterialTheme.typography.bodySmall,
                                color = PeeringColors.muted,
                            )
                        }
                    },
                    onClick = {
                        open = false
                        onPick(mode)
                    },
                )
            }
        }
    }
}

@Composable
fun ModelMenu(
    current: String?,
    choices: List<String>,
    onPick: (String?) -> Unit,
) {
    var open by remember { mutableStateOf(false) }
    Box {
        TextButton(onClick = { open = true }, enabled = choices.isNotEmpty()) {
            Text(current ?: stringResource(R.string.composer_model_default), style = MaterialTheme.typography.labelLarge, color = PeeringColors.ink)
        }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            DropdownMenuItem(
                text = { Text(stringResource(R.string.composer_model_default)) },
                onClick = {
                    open = false
                    onPick(null)
                },
            )
            choices.forEach { model ->
                DropdownMenuItem(
                    text = { Text(model) },
                    onClick = {
                        open = false
                        onPick(model)
                    },
                )
            }
        }
    }
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
