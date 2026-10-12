package pl.dmq.peering.feature.onboarding

import androidx.compose.animation.animateContentSize
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
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
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import pl.dmq.peering.R
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.kit.Motion
import pl.dmq.peering.ui.kit.ControlsCard
import pl.dmq.peering.ui.kit.ControlsDivider
import pl.dmq.peering.ui.kit.TabScreen
import pl.dmq.peering.ui.kit.tappable
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText

/** The questions and answers from [FaqEntries], each section a card and each answer opening in place. */
@Composable
fun FaqScreen(modifier: Modifier = Modifier, bottomClearance: Dp = 36.dp) {
    TabScreen(
        title = stringResource(R.string.nav_faq),
        detail = stringResource(R.string.faq_detail),
        modifier = modifier,
        bottomClearance = bottomClearance,
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
    }
}

@Composable
private fun FaqRow(item: FaqItem) {
    var open by rememberSaveable(item.questionRes) { mutableStateOf(false) }
    val turn = animateFloatAsState(if (open) 90f else 0f, Motion.standard(), label = "chevron")
    Column(Modifier.fillMaxWidth().animateContentSize(Motion.spring())) {
        Row(
            Modifier.fillMaxWidth().tappable({ open = !open }, role = Role.Button).padding(vertical = 11.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                stringResource(item.questionRes),
                style = PeeringText.subheadlineSemibold,
                color = PeeringColors.ink,
                modifier = Modifier.weight(1f).padding(end = 10.dp),
            )
            Icon(AppIcons.chevronRight, null, tint = PeeringColors.tertiary, modifier = Modifier.size(14.dp).graphicsLayer { rotationZ = turn.value })
        }
        if (open) {
            Text(
                stringResource(item.answerRes),
                style = PeeringText.subheadline.copy(fontSize = 16.sp, lineHeight = 21.sp),
                color = PeeringColors.muted,
                modifier = Modifier.padding(bottom = 12.dp),
            )
        }
    }
}
