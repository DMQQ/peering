package pl.dmq.peering.feature.agents.changes

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.session.agent.changes.PushBlock
import pl.dmq.peering.session.agent.changes.PushOffer
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.kit.InkButton
import pl.dmq.peering.ui.kit.PeeringAlert
import pl.dmq.peering.ui.kit.PeeringSheet
import pl.dmq.peering.ui.kit.PeeringTextField
import pl.dmq.peering.ui.theme.OutlinedPanel
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText
import pl.dmq.peering.wire.AgentChangeKind
import pl.dmq.peering.wire.AgentGitOperation
import pl.dmq.peering.wire.AgentGitResult

/** Commit chosen files, then, as a step of its own, push. The computer decides what git runs; this only asks. */
@Composable
fun CommitSheet(presenter: CommitPresenter, onDismiss: () -> Unit) {
    val ui by presenter.ui.collectAsState()
    var confirmingCommit by remember { mutableStateOf(false) }
    var confirmingPush by remember { mutableStateOf(false) }
    PeeringSheet(onDismiss = onDismiss, title = stringResource(R.string.commit_title), scrollable = true) {
        Column(Modifier.padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            FilesCard(ui, presenter, onCommit = { confirmingCommit = true })
            ui.result?.let { ResultCard(it) }
            PushCard(ui, onPush = { confirmingPush = true })
        }
    }
    if (confirmingCommit) {
        val branch = ui.branch ?: stringResource(R.string.commit_this_folder)
        PeeringAlert(
            title = pluralStringResource(R.plurals.commit_confirm_title, ui.chosenCount, ui.chosenCount, branch),
            message = ui.message,
            confirm = stringResource(R.string.commit_confirm),
            onConfirm = {
                confirmingCommit = false
                presenter.commit()
            },
            cancel = stringResource(R.string.changes_comment_cancel),
            onCancel = { confirmingCommit = false },
        )
    }
    val offer = ui.push as? PushOffer.Ready
    if (confirmingPush && offer != null) {
        PeeringAlert(
            title = stringResource(R.string.push_confirm_title, offer.branch, offer.upstream),
            message = pluralStringResource(R.plurals.push_ready, offer.ahead, offer.ahead, offer.branch, offer.upstream),
            confirm = stringResource(R.string.push_button),
            onConfirm = {
                confirmingPush = false
                presenter.push()
            },
            cancel = stringResource(R.string.changes_comment_cancel),
            onCancel = { confirmingPush = false },
        )
    }
}

@Composable
private fun FilesCard(ui: CommitUi, presenter: CommitPresenter, onCommit: () -> Unit) {
    OutlinedPanel(Modifier.fillMaxWidth()) {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text(stringResource(R.string.commit_files), style = PeeringText.subheadlineSemibold, color = PeeringColors.ink)
            if (ui.files.isEmpty()) Text(stringResource(R.string.commit_none), style = PeeringText.subheadline, color = PeeringColors.muted)
            ui.files.forEach { file -> FileChoice(file, onToggle = { presenter.toggle(file.path) }) }
            PeeringTextField(
                value = ui.message,
                onValueChange = presenter::editMessage,
                label = stringResource(R.string.commit_message),
                singleLine = false,
                modifier = Modifier.fillMaxWidth(),
            )
            val busy = ui.busy == AgentGitOperation.COMMIT
            ActionButton(
                title = if (busy) stringResource(R.string.commit_busy) else pluralStringResource(R.plurals.commit_button, ui.chosenCount, ui.chosenCount),
                busy = busy,
                enabled = ui.canCommit,
                onClick = onCommit,
            )
        }
    }
}

@Composable
private fun FileChoice(file: CommitFileUi, onToggle: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().clickable(role = Role.Checkbox, onClick = onToggle),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Icon(
            if (file.chosen) AppIcons.checkCircleFilled else AppIcons.circle,
            contentDescription = null,
            tint = PeeringColors.ink.copy(alpha = if (file.chosen) 0.95f else 0.4f),
            modifier = Modifier.size(22.dp),
        )
        Text(
            file.path,
            style = PeeringText.footnote.copy(fontFamily = FontFamily.Monospace),
            color = PeeringColors.ink,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f),
        )
        val counts = if (file.kind == AgentChangeKind.UNTRACKED) "U" else "+${file.added} -${file.removed}"
        Text(counts, style = PeeringText.caption.copy(fontFamily = FontFamily.Monospace), color = PeeringColors.faint)
    }
}

@Composable
private fun ResultCard(result: AgentGitResult) {
    val title = when (result.operation) {
        AgentGitOperation.COMMIT -> if (result.succeeded) R.string.commit_done else R.string.commit_failed
        AgentGitOperation.PUSH -> if (result.succeeded) R.string.push_done else R.string.push_failed
    }
    OutlinedPanel(Modifier.fillMaxWidth()) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Icon(if (result.succeeded) AppIcons.checkCircle else AppIcons.warning, contentDescription = null, tint = PeeringColors.ink, modifier = Modifier.size(18.dp))
            Text(stringResource(title), style = PeeringText.subheadlineSemibold, color = PeeringColors.ink)
        }
        Text(
            result.message,
            style = PeeringText.caption.copy(fontFamily = FontFamily.Monospace),
            color = PeeringColors.ink.copy(alpha = 0.7f),
            modifier = Modifier.padding(top = 6.dp),
        )
    }
}

@Composable
private fun PushCard(ui: CommitUi, onPush: () -> Unit) {
    OutlinedPanel(Modifier.fillMaxWidth()) {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text(stringResource(R.string.push_title), style = PeeringText.subheadlineSemibold, color = PeeringColors.ink)
            when (val offer = ui.push) {
                is PushOffer.Ready -> {
                    Text(
                        pluralStringResource(R.plurals.push_ready, offer.ahead, offer.ahead, offer.branch, offer.upstream),
                        style = PeeringText.subheadline,
                        color = PeeringColors.muted,
                    )
                    val busy = ui.busy == AgentGitOperation.PUSH
                    ActionButton(
                        title = stringResource(if (busy) R.string.push_busy else R.string.push_button),
                        busy = busy,
                        enabled = ui.busy == null,
                        onClick = onPush,
                    )
                }
                PushOffer.NothingToPush ->
                    Text(stringResource(R.string.push_nothing), style = PeeringText.subheadline, color = PeeringColors.muted)
                is PushOffer.Blocked -> Text(
                    stringResource(
                        when (offer.reason) {
                            PushBlock.UNREADABLE -> R.string.push_unreadable
                            PushBlock.DETACHED_HEAD -> R.string.push_detached
                            PushBlock.NO_UPSTREAM -> R.string.push_no_upstream
                        },
                    ),
                    style = PeeringText.subheadline,
                    color = PeeringColors.muted,
                )
            }
        }
    }
}

@Composable
private fun ActionButton(title: String, busy: Boolean, enabled: Boolean, onClick: () -> Unit) {
    InkButton(onClick = onClick, enabled = enabled, modifier = Modifier.fillMaxWidth()) {
        if (busy) {
            CircularProgressIndicator(color = PeeringColors.onInk, strokeWidth = 2.dp, modifier = Modifier.size(16.dp))
            Spacer(Modifier.width(8.dp))
        }
        Text(title)
    }
}
