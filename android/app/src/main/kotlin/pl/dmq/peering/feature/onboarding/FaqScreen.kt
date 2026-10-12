package pl.dmq.peering.feature.onboarding

import androidx.compose.animation.core.tween
import androidx.compose.animation.animateContentSize
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.ui.kit.ControlsCard
import pl.dmq.peering.ui.kit.TitleBarScreen
import pl.dmq.peering.ui.kit.ControlsDivider
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.kit.tappable
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText

/** The questions and answers from [FaqEntries], each section a card and each answer opening in place. */
@Composable
fun FaqScreen(modifier: Modifier = Modifier, bottomClearance: Dp = 24.dp) {
    TitleBarScreen(
        title = stringResource(R.string.nav_faq),
        detail = stringResource(R.string.faq_detail),
        modifier = modifier,
    ) {
        FaqEntries.sections.forEach { section ->
            ControlsCard(stringResource(section.titleRes)) {
                Column {
                    section.items.forEachIndexed { index, item ->
                        FaqRow(item)
                        if (index != section.items.lastIndex) ControlsDivider()
                    }
                }
            }
        }
        Spacer(Modifier.height(bottomClearance))
    }
}

@Composable
private fun FaqRow(item: FaqItem) {
    var open by rememberSaveable(item.questionRes) { mutableStateOf(false) }
    val turn by animateFloatAsState(if (open) 180f else 0f, tween(durationMillis = 200), label = "chevron")
    Column(Modifier.fillMaxWidth().animateContentSize()) {
        Row(
            Modifier.fillMaxWidth().tappable({ open = !open }).padding(vertical = 11.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                stringResource(item.questionRes),
                style = PeeringText.subheadlineSemibold.copy(fontWeight = FontWeight.SemiBold),
                color = PeeringColors.ink,
                modifier = Modifier.weight(1f),
            )
            Icon(AppIcons.expand, null, tint = PeeringColors.tertiary, modifier = Modifier.size(14.dp).rotate(turn))
        }
        if (open) {
            Text(stringResource(item.answerRes), style = PeeringText.footnote.copy(fontSize = PeeringText.subheadline.fontSize), color = PeeringColors.muted, modifier = Modifier.padding(bottom = 12.dp))
        }
    }
}
