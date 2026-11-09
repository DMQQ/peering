package pl.dmq.peering.feature.agents.routines

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.feature.agents.AgentOption
import pl.dmq.peering.feature.agents.PermissionModeCopy
import pl.dmq.peering.feature.agents.permissionDetail
import pl.dmq.peering.feature.agents.permissionIcon
import pl.dmq.peering.feature.agents.permissionTitle
import pl.dmq.peering.session.agent.routines.AgentRoutineDraft
import pl.dmq.peering.session.files.FilePath
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.kit.ControlLink
import pl.dmq.peering.ui.kit.ControlPicker
import pl.dmq.peering.ui.kit.ControlToggle
import pl.dmq.peering.ui.kit.ControlsCard
import pl.dmq.peering.ui.kit.ControlsDivider
import pl.dmq.peering.ui.kit.LinkButton
import pl.dmq.peering.ui.kit.PeeringAlert
import pl.dmq.peering.ui.kit.PeeringTextField
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText
import pl.dmq.peering.wire.AgentPermissionMode

private val STOP_AFTER_CHOICES: List<Int?> = listOf(null, 15, 30, 60, 120, 240)

/** Makes or changes one routine. Nothing reaches the computer until Save. */
@Composable
internal fun RoutineEditor(page: RoutinesPage.Editor, agents: List<AgentOption>, presenter: RoutinesPresenter, modifier: Modifier = Modifier) {
    val draft = page.draft
    var confirmsDelete by rememberSaveable { mutableStateOf(false) }
    var pendingAutoMode by rememberSaveable { mutableStateOf(false) }
    val problem = draft.problem
    Column(modifier.fillMaxSize().imePadding()) {
        Row(Modifier.fillMaxWidth().statusBarsPadding().padding(horizontal = 4.dp), verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = { presenter.back() }) {
                Icon(AppIcons.back, contentDescription = stringResource(R.string.agents_back), tint = PeeringColors.ink)
            }
            Text(
                if (page.isNew) stringResource(R.string.routines_new) else draft.name,
                style = PeeringText.headline,
                color = PeeringColors.ink,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f),
            )
            if (problem == null) {
                LinkButton(stringResource(R.string.routines_save), presenter::save)
            } else {
                Text(stringResource(R.string.routines_save), style = PeeringText.subheadlineSemibold, color = PeeringColors.faint, modifier = Modifier.padding(end = 12.dp))
            }
        }
        Column(
            Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(16.dp).navigationBarsPadding(),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            WhatCard(draft, agents, presenter)
            RoutineScheduleCard(draft, presenter)
            PermissionsCard(draft, presenter, onAutoRequested = { pendingAutoMode = true })
            if (problem != null) Text(problemText(problem), style = PeeringText.footnote, color = PeeringColors.muted)
            if (!page.isNew) {
                LinkButton(stringResource(R.string.routines_delete), { confirmsDelete = true }, Modifier.fillMaxWidth())
            }
        }
    }
    if (confirmsDelete) {
        PeeringAlert(
            title = stringResource(R.string.routines_delete_title),
            message = stringResource(R.string.routines_delete_message),
            confirm = stringResource(R.string.routines_delete),
            onConfirm = {
                confirmsDelete = false
                presenter.delete()
            },
            cancel = stringResource(R.string.routines_cancel),
            onCancel = { confirmsDelete = false },
            destructive = true,
        )
    }
    if (pendingAutoMode) {
        PeeringAlert(
            title = stringResource(R.string.routines_auto_title),
            message = stringResource(R.string.routines_auto_message),
            confirm = stringResource(R.string.routines_auto_confirm),
            onConfirm = {
                pendingAutoMode = false
                presenter.change { it.copy(permissionMode = AgentPermissionMode.AUTO) }
            },
            cancel = stringResource(R.string.routines_cancel),
            onCancel = { pendingAutoMode = false },
            destructive = true,
        )
    }
}

@Composable
private fun WhatCard(draft: AgentRoutineDraft, agents: List<AgentOption>, presenter: RoutinesPresenter) {
    ControlsCard(stringResource(R.string.routines_card_routine)) {
        PeeringTextField(draft.name, { value -> presenter.change { it.copy(name = value) } }, stringResource(R.string.routines_name), Modifier.fillMaxWidth())
        ControlsDivider()
        ControlPicker(
            title = stringResource(R.string.routines_agent),
            icon = AppIcons.sparkles,
            selected = draft.agentID,
            options = agents.map { it.id },
            optionTitle = { id -> agents.firstOrNull { it.id == id }?.name ?: id },
            onSelect = presenter::chooseAgent,
        )
        ControlsDivider()
        ControlLink(
            title = stringResource(R.string.routines_folder),
            icon = AppIcons.folder,
            onClick = presenter::chooseFolder,
            detail = draft.directory?.let(FilePath::name) ?: stringResource(R.string.routines_choose),
        )
        ControlsDivider()
        PeeringTextField(
            draft.prompt,
            { value -> presenter.change { it.copy(prompt = value) } },
            stringResource(R.string.routines_prompt),
            Modifier.fillMaxWidth(),
            singleLine = false,
        )
    }
}

@Composable
private fun PermissionsCard(draft: AgentRoutineDraft, presenter: RoutinesPresenter, onAutoRequested: () -> Unit) {
    val detail = permissionDetail(PermissionModeCopy.detail(draft.permissionMode, draft.agentID))
    ControlsCard(stringResource(R.string.routines_card_while_running), footer = stringResource(detail)) {
        ControlPicker(
            title = stringResource(R.string.routines_permissions),
            icon = permissionIcon(draft.permissionMode),
            selected = draft.permissionMode,
            options = presenter.modes(draft.agentID),
            optionTitle = { stringResource(permissionTitle(it)) },
            onSelect = { mode -> if (mode == AgentPermissionMode.AUTO) onAutoRequested() else presenter.change { it.copy(permissionMode = mode) } },
        )
        ControlsDivider()
        ControlPicker(
            title = stringResource(R.string.routines_stop_after),
            icon = AppIcons.clockAlert,
            selected = draft.stopAfterMinutes,
            options = if (draft.stopAfterMinutes in STOP_AFTER_CHOICES) STOP_AFTER_CHOICES else STOP_AFTER_CHOICES + draft.stopAfterMinutes,
            optionTitle = { minutes -> if (minutes == null) stringResource(R.string.routines_no_limit) else durationText(minutes) },
            onSelect = { minutes -> presenter.change { it.copy(stopAfterMinutes = minutes) } },
        )
        ControlsDivider()
        ControlToggle(stringResource(R.string.routines_notify), AppIcons.notification, draft.notifiesWhenDone, { on -> presenter.change { it.copy(notifiesWhenDone = on) } })
        ControlsDivider()
        ControlToggle(stringResource(R.string.routines_on), AppIcons.power, draft.isEnabled, { on -> presenter.change { it.copy(isEnabled = on) } })
    }
}
