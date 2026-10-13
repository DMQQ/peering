package pl.dmq.peering.feature.agents

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
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
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.session.agent.AgentChatState
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.kit.PeeringMenu
import pl.dmq.peering.ui.kit.PeeringMenuItem
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText
import pl.dmq.peering.ui.theme.PillShape
import pl.dmq.peering.wire.AgentSessionState

/** One open chat as its tab shows it. */
data class ChatTab(val id: String, val title: String, val state: AgentSessionState, val selected: Boolean) {
    companion object {
        /** The open chats in the order the hub has them. A lone chat has no strip to switch within. */
        fun of(chats: AgentChatState): List<ChatTab> =
            if (chats.sessions.size < 2) emptyList() else chats.sessions.map { ChatTab(it.id, it.title, it.state, it.id == chats.selectedSessionID) }
    }
}

/** Switches between the open chats without going back to the hub. A long press renames or closes one. */
@Composable
internal fun ChatTabStrip(tabs: List<ChatTab>, onSelect: (String) -> Unit, onRename: (String) -> Unit, onClose: (String) -> Unit, modifier: Modifier = Modifier) {
    Row(
        modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal = 12.dp, vertical = 4.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        tabs.forEach { tab -> ChatTabChip(tab, onSelect, onRename, onClose) }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun ChatTabChip(tab: ChatTab, onSelect: (String) -> Unit, onRename: (String) -> Unit, onClose: (String) -> Unit) {
    var menuOpen by remember { mutableStateOf(false) }
    Box {
        Row(
            Modifier
                .heightIn(min = 32.dp)
                .clip(PillShape)
                .background(if (tab.selected) PeeringColors.ink.copy(alpha = 0.14f) else PeeringColors.ink.copy(alpha = 0.05f))
                .combinedClickable(onClick = { onSelect(tab.id) }, onLongClick = { menuOpen = true })
                .padding(horizontal = 12.dp)
                .semantics { selected = tab.selected },
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            Icon(
                when (tab.state) {
                    AgentSessionState.AWAITING_APPROVAL -> AppIcons.privacy
                    AgentSessionState.FAILED -> AppIcons.warning
                    else -> AppIcons.sparkles
                },
                contentDescription = null,
                tint = when (tab.state) {
                    AgentSessionState.AWAITING_APPROVAL -> PeeringColors.caution
                    AgentSessionState.FAILED -> PeeringColors.danger
                    AgentSessionState.WORKING -> PeeringColors.ink.copy(alpha = 0.8f)
                    else -> PeeringColors.muted
                },
                modifier = Modifier.size(13.dp),
            )
            Text(
                tab.title,
                style = PeeringText.footnote.copy(fontWeight = if (tab.selected) FontWeight.SemiBold else FontWeight.Medium),
                color = if (tab.selected) PeeringColors.ink else PeeringColors.muted,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.widthIn(max = 160.dp),
            )
        }
        PeeringMenu(menuOpen, { menuOpen = false }) {
            PeeringMenuItem(stringResource(R.string.agents_rename), icon = AppIcons.edit, onClick = {
                menuOpen = false
                onRename(tab.id)
            })
            PeeringMenuItem(stringResource(R.string.agents_close_chat_menu), icon = AppIcons.close, destructive = true, onClick = {
                menuOpen = false
                onClose(tab.id)
            })
        }
    }
}
