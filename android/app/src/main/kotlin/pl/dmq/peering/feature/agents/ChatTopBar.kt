package pl.dmq.peering.feature.agents

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import pl.dmq.peering.R
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.kit.PeeringMenu
import pl.dmq.peering.ui.kit.PeeringMenuDivider
import pl.dmq.peering.ui.kit.PeeringMenuItem
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText

/** Back, the agent's name over the folder in monospace, and the options menu in the trailing corner. */
@Composable
fun ChatTopBar(
    ui: ChatUi,
    onBack: () -> Unit,
    onShowUsage: () -> Unit,
    onShowChanges: () -> Unit,
    onPause: () -> Unit,
    onClose: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier = modifier.fillMaxWidth().statusBarsPadding().padding(horizontal = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        IconButton(onClick = onBack) {
            Icon(AppIcons.back, contentDescription = stringResource(R.string.agents_back_to_list), tint = PeeringColors.ink)
        }
        Column(Modifier.weight(1f), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(1.dp)) {
            Text(
                ui.agentName.ifEmpty { ui.title },
                style = PeeringText.subheadlineSemibold.copy(fontSize = 15.sp),
                color = PeeringColors.ink,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                ui.directory,
                style = PeeringText.caption2Monospaced,
                color = PeeringColors.muted,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                textAlign = TextAlign.Center,
            )
        }
        ChatMenu(ui, onShowUsage, onShowChanges, onPause, onClose)
    }
}

@Composable
private fun ChatMenu(ui: ChatUi, onShowUsage: () -> Unit, onShowChanges: () -> Unit, onPause: () -> Unit, onClose: () -> Unit) {
    var open by remember { mutableStateOf(false) }
    Box {
        IconButton(onClick = { open = true }) {
            Icon(AppIcons.more, contentDescription = stringResource(R.string.agents_chat_options), tint = PeeringColors.ink)
        }
        PeeringMenu(open, { open = false }) {
            if (ui.usageSupported) {
                PeeringMenuItem(
                    title = stringResource(R.string.agents_usage_title),
                    icon = AgentIcons.usage,
                    onClick = {
                        open = false
                        onShowUsage()
                    },
                )
            }
            PeeringMenuItem(
                title = stringResource(R.string.changes_menu),
                icon = AgentIcons.changes,
                onClick = {
                    open = false
                    onShowChanges()
                },
            )
            if (ui.canPause) {
                PeeringMenuItem(
                    title = stringResource(R.string.agents_stop_to_history),
                    icon = AgentIcons.archive,
                    destructive = true,
                    onClick = {
                        open = false
                        onPause()
                    },
                )
            }
            PeeringMenuDivider()
            PeeringMenuItem(
                title = stringResource(R.string.agents_close_chat_menu),
                icon = AppIcons.close,
                destructive = true,
                onClick = {
                    open = false
                    onClose()
                },
            )
        }
    }
}
