package pl.dmq.peering.feature.agents

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import pl.dmq.peering.R
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText
import pl.dmq.peering.ui.theme.PillShape

/**
 * The floating bar at the bottom of the page: one ink capsule that chats with the selected agent, or asks which agent
 * while none is selected. Holding it reopens the choice when there is more than one.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun HubDock(
    agent: AgentOption?,
    canChooseAgent: Boolean,
    onChat: () -> Unit,
    onChoose: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val haptics = LocalHapticFeedback.current
    val label = if (agent != null) stringResource(R.string.agents_dock_chat_with, agent.name) else stringResource(R.string.agents_dock_choose)
    val choose = stringResource(R.string.agents_dock_choose_action)
    Box(
        modifier = modifier
            .fillMaxWidth()
            .background(Brush.verticalGradient(listOf(Color.Transparent, PeeringColors.backdrop)))
            .padding(start = 16.dp, end = 16.dp, top = 8.dp, bottom = 6.dp),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .height(48.dp)
                .clip(PillShape)
                .background(PeeringColors.ink)
                .combinedClickable(
                    role = Role.Button,
                    onClick = if (agent != null) onChat else onChoose,
                    onLongClick = if (agent != null && canChooseAgent) {
                        {
                            haptics.performHapticFeedback(HapticFeedbackType.LongPress)
                            onChoose()
                        }
                    } else {
                        null
                    },
                )
                .semantics { if (agent != null && canChooseAgent) customActions = listOf(CustomAccessibilityAction(choose) { onChoose(); true }) }
                .padding(start = 8.dp, end = 14.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp, Alignment.CenterHorizontally),
        ) {
            Box(Modifier.size(32.dp).clip(PillShape).background(PeeringColors.onInk), contentAlignment = Alignment.Center) {
                Icon(
                    if (agent != null) AgentBrand.of(agent.id).icon() else AppIcons.sparkles,
                    contentDescription = null,
                    tint = PeeringColors.ink,
                    modifier = Modifier.size(16.dp),
                )
            }
            Text(
                label,
                style = PeeringText.subheadlineSemibold.copy(fontSize = 15.5.sp, fontWeight = FontWeight.SemiBold),
                color = PeeringColors.onInk,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}
