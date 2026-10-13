package pl.dmq.peering.feature.agents

import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.FactCheck
import androidx.compose.material.icons.outlined.Notes
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.session.agent.FollowUp
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.kit.tappable
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText
import pl.dmq.peering.ui.theme.PillShape

/** What to do next after a turn that changed the project, as buttons over the composer. */
@Composable
internal fun FollowUpBar(suggestions: List<FollowUp>, onChoose: (FollowUp) -> Unit, modifier: Modifier = Modifier) {
    Row(
        modifier.fillMaxWidth().padding(top = 6.dp).horizontalScroll(rememberScrollState()).padding(horizontal = 14.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        suggestions.forEach { suggestion ->
            Row(
                Modifier.heightIn(min = 32.dp).clip(PillShape).border(1.dp, PeeringColors.outline, PillShape)
                    .tappable({ onChoose(suggestion) }).padding(horizontal = 12.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                Icon(suggestion.icon, contentDescription = null, tint = PeeringColors.ink.copy(alpha = 0.85f), modifier = Modifier.size(14.dp))
                Text(stringResource(suggestion.title), style = PeeringText.footnote, color = PeeringColors.ink.copy(alpha = 0.85f))
            }
        }
    }
}

private val FollowUp.icon: ImageVector get() = when (this) {
    FollowUp.REVIEW_CHANGES -> AppIcons.document
    FollowUp.RUN_TESTS -> Icons.Outlined.FactCheck
    FollowUp.SUMMARIZE_CHANGES -> Icons.Outlined.Notes
}

private val FollowUp.title: Int get() = when (this) {
    FollowUp.REVIEW_CHANGES -> R.string.followup_review
    FollowUp.RUN_TESTS -> R.string.followup_tests
    FollowUp.SUMMARIZE_CHANGES -> R.string.followup_summarize
}
