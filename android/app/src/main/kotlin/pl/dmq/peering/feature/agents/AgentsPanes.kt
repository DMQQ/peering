package pl.dmq.peering.feature.agents

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.width
import androidx.compose.material3.VerticalDivider
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.ui.kit.DepthTransition
import pl.dmq.peering.ui.theme.EmptyState
import pl.dmq.peering.ui.theme.PeeringColors

private val LIST_PANE_WIDTH = 380.dp

/**
 * The hub and the open chat. On a narrow window the chat takes the screen over the hub; on a wide one the hub stays as a
 * list down the left with the chat beside it, and a quiet note where the chat goes until one is opened.
 */
@Composable
internal fun AgentsPanes(
    twoPane: Boolean,
    chatOpen: Boolean,
    hub: @Composable () -> Unit,
    chat: @Composable () -> Unit,
    modifier: Modifier = Modifier,
) {
    if (twoPane) {
        Row(modifier.fillMaxSize()) {
            Box(Modifier.width(LIST_PANE_WIDTH).fillMaxHeight()) { hub() }
            VerticalDivider(color = PeeringColors.hairline)
            Box(Modifier.weight(1f).fillMaxHeight(), contentAlignment = Alignment.Center) {
                if (chatOpen) {
                    chat()
                } else {
                    EmptyState(icon = null, title = stringResource(R.string.agents_pane_empty_title), body = stringResource(R.string.agents_pane_empty_body), mascot = true)
                }
            }
        }
    } else {
        DepthTransition(state = chatOpen, depth = { if (it) 1 else 0 }, modifier = modifier, label = "agentsChat") { open ->
            if (open) chat() else hub()
        }
    }
}
