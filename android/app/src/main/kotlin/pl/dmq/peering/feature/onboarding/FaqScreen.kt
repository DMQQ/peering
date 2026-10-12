package pl.dmq.peering.feature.onboarding

import androidx.compose.animation.animateContentSize
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
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
import pl.dmq.peering.ui.kit.ControlsDivider
import pl.dmq.peering.ui.kit.Symbols
import pl.dmq.peering.ui.kit.pressable
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringMotion
import pl.dmq.peering.ui.theme.PeeringText
import pl.dmq.peering.ui.theme.ScreenHeader
import pl.dmq.peering.ui.theme.arrive

/** The questions and answers from [FaqEntries], each section a card and each answer opening in place. */
@Composable
fun FaqScreen(modifier: Modifier = Modifier, bottomClearance: Dp = 24.dp) {
    Column(
        modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 18.dp).padding(top = 16.dp, bottom = bottomClearance),
        verticalArrangement = Arrangement.spacedBy(18.dp),
    ) {
        ScreenHeader(stringResource(R.string.nav_faq), Modifier.arrive(), detail = stringResource(R.string.faq_detail))
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
    }
}

@Composable
private fun FaqRow(item: FaqItem) {
    var open by rememberSaveable(item.questionRes) { mutableStateOf(false) }
    val turn by animateFloatAsState(if (open) 90f else 0f, PeeringMotion.settle, label = "chevron")
    Column(Modifier.fillMaxWidth().animateContentSize()) {
        Row(
            Modifier.fillMaxWidth().pressable({ open = !open }, scale = 0.99f).padding(vertical = 11.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                stringResource(item.questionRes),
                style = PeeringText.subheadlineSemibold.copy(fontWeight = FontWeight.SemiBold),
                color = PeeringColors.ink,
                modifier = Modifier.weight(1f),
            )
            Icon(Symbols.chevronRight, null, tint = PeeringColors.tertiary, modifier = Modifier.size(14.dp).rotate(turn))
        }
        if (open) {
            Text(stringResource(item.answerRes), style = PeeringText.footnote.copy(fontSize = PeeringText.subheadline.fontSize), color = PeeringColors.muted, modifier = Modifier.padding(bottom = 12.dp))
        }
    }
}
