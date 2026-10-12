package pl.dmq.peering.feature.terminal

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.session.terminal.TerminalTab
import pl.dmq.peering.ui.kit.PeeringSpinner
import pl.dmq.peering.ui.kit.QuietButton
import pl.dmq.peering.ui.theme.EmptyState
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.wire.TerminalAttentionKind

/** No list yet: the computer has not answered. */
@Composable
fun TerminalLoading(waitingForConnection: Boolean, modifier: Modifier = Modifier) {
    Box(modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp)) {
            PeeringSpinner()
            Text(
                stringResource(if (waitingForConnection) R.string.terminal_reconnecting else R.string.terminal_loading),
                style = MaterialTheme.typography.bodyMedium,
                color = PeeringColors.muted,
            )
        }
    }
}

/** The list came back empty, or opening a shell failed. */
@Composable
fun TerminalEmpty(failure: String?, onNew: () -> Unit, modifier: Modifier = Modifier) {
    Box(modifier.fillMaxSize().padding(24.dp), contentAlignment = Alignment.Center) {
        EmptyState(
            icon = TerminalGlyphs.terminal,
            title = stringResource(R.string.terminal_empty_title),
            body = failure ?: stringResource(R.string.terminal_empty_body),
            action = {
                QuietButton(onClick = onNew) { Text(stringResource(R.string.terminal_new)) }
            },
        )
    }
}

/** A line above the screen for what the shell or the computer has to say: an exit, a wait, or a failure. */
@Composable
fun TerminalNotice(tab: TerminalTab, failure: String?, onNew: () -> Unit, onDismissFailure: () -> Unit, modifier: Modifier = Modifier) {
    val text = noticeText(tab, failure) ?: return
    val isProblem = failure != null || tab.failure != null || (tab.exitStatus ?: 0) != 0
    Row(
        modifier = modifier.fillMaxWidth().padding(horizontal = 16.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.SpaceBetween,
    ) {
        Text(
            text,
            modifier = Modifier.weight(1f),
            style = MaterialTheme.typography.bodySmall,
            color = if (isProblem) PeeringColors.danger else PeeringColors.muted,
        )
        when {
            failure != null -> TextButton(onClick = onDismissFailure) { Text(stringResource(R.string.terminal_dismiss)) }
            !tab.isRunning -> TextButton(onClick = onNew) { Text(stringResource(R.string.terminal_new)) }
        }
    }
}

@Composable
private fun noticeText(tab: TerminalTab, failure: String?): String? = when {
    failure != null -> failure
    tab.failure != null -> tab.failure
    !tab.isRunning -> tab.exitStatus?.takeIf { it != 0 }?.let { stringResource(R.string.terminal_exited, it) }
        ?: stringResource(R.string.terminal_exited_ok)
    tab.attention == TerminalAttentionKind.PASSWORD -> stringResource(R.string.terminal_attention_password)
    tab.attention == TerminalAttentionKind.CONFIRMATION -> stringResource(R.string.terminal_attention_confirmation)
    else -> null
}
