package pl.dmq.peering.feature.agents

import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.kit.PeeringMenu
import pl.dmq.peering.ui.kit.PeeringMenuItem
import pl.dmq.peering.ui.theme.PeeringColors

/** One chat: a top bar with back, the usage chip and the options menu, the conversation, and the composer. */
@Composable
fun ChatScreen(
    chat: ChatPresenter,
    transcript: TranscriptPresenter,
    composer: ComposerPresenter,
    port: AgentsPort,
    onBackToList: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val ui by chat.ui.collectAsState()
    var showingUsage by remember { mutableStateOf(false) }
    Column(modifier = modifier.fillMaxSize()) {
        ChatTopBar(
            ui = ui,
            onBack = onBackToList,
            onShowUsage = { showingUsage = true },
            onPause = { if (chat.pause()) onBackToList() },
            onClose = {
                chat.close()
                onBackToList()
            },
        )
        Box(modifier = Modifier.weight(1f)) {
            TranscriptList(presenter = transcript, port = port, modifier = Modifier.fillMaxSize())
            if (ui.showEmptyState) EmptyChat(ui = ui, onSuggest = chat::suggest)
        }
        Composer(presenter = composer)
    }
    if (showingUsage) UsageSheet(usage = ui.usage, onDismiss = { showingUsage = false })
}

@Composable
private fun ChatTopBar(
    ui: ChatUi,
    onBack: () -> Unit,
    onShowUsage: () -> Unit,
    onPause: () -> Unit,
    onClose: () -> Unit,
) {
    Row(
        modifier = Modifier.fillMaxWidth().padding(horizontal = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        IconButton(onClick = onBack, modifier = Modifier.size(48.dp)) {
            Icon(AppIcons.back, contentDescription = stringResource(R.string.agents_back_to_list), tint = PeeringColors.ink)
        }
        Column(modifier = Modifier.weight(1f)) {
            Text(ui.title, style = MaterialTheme.typography.titleMedium, color = PeeringColors.ink, maxLines = 1)
            Text(ui.directory, style = MaterialTheme.typography.bodySmall, color = PeeringColors.muted, maxLines = 1)
        }
        ui.chip?.let { ContextChipButton(it, onClick = onShowUsage) }
        ChatMenu(ui, onShowUsage, onPause, onClose)
    }
}

@Composable
private fun ContextChipButton(chip: ContextChip, onClick: () -> Unit) {
    val tint = if (chip.nearlyFull) PeeringColors.caution else PeeringColors.muted
    Box(modifier = Modifier.heightIn(min = 48.dp).clip(CircleShape).clickable(onClick = onClick), contentAlignment = Alignment.Center) {
        Text(
            chipText(chip),
            style = MaterialTheme.typography.labelMedium,
            color = tint,
            maxLines = 1,
            modifier = Modifier.border(1.dp, PeeringColors.hairline, CircleShape).padding(horizontal = 12.dp, vertical = 6.dp),
        )
    }
}

@Composable
private fun chipText(chip: ContextChip): String {
    val parts = listOfNotNull(chip.contextLabel, chip.fiveHourPercent?.let { "5h $it%" })
    return parts.joinToString("  ·  ")
}

@Composable
private fun ChatMenu(ui: ChatUi, onShowUsage: () -> Unit, onPause: () -> Unit, onClose: () -> Unit) {
    var open by remember { mutableStateOf(false) }
    Box {
        IconButton(onClick = { open = true }, modifier = Modifier.size(48.dp)) {
            Icon(AppIcons.more, contentDescription = stringResource(R.string.agents_chat_options), tint = PeeringColors.ink)
        }
        PeeringMenu(open, { open = false }) {
            if (ui.usageSupported) {
                PeeringMenuItem(
                    title = stringResource(R.string.agents_usage_title),
                    onClick = {
                        open = false
                        onShowUsage()
                    },
                )
            }
            if (ui.canPause) {
                PeeringMenuItem(
                    title = stringResource(R.string.agents_stop_to_history),
                    onClick = {
                        open = false
                        onPause()
                    },
                )
            }
            PeeringMenuItem(
                title = stringResource(R.string.agents_end_chat),
                destructive = true,
                onClick = {
                    open = false
                    onClose()
                },
            )
        }
    }
}
