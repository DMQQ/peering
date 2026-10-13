package pl.dmq.peering.feature.onboarding

import androidx.compose.ui.draw.clip
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.ui.unit.sp
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.kit.CardShape
import pl.dmq.peering.ui.kit.pressable
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText

/** One plan to choose between: a radio, its name and what it gives, and the price when it has one. The chosen card is ringed in the accent. */
@Composable
internal fun PlanCard(
    title: String,
    detail: String,
    selected: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    price: String? = null,
    priceCaption: String? = null,
    badge: String? = null,
) {
    Row(
        modifier = modifier
            .fillMaxWidth()
            .pressable(onClick, role = Role.RadioButton)
            .clip(CardShape)
            .semantics { role = Role.RadioButton; this.selected = selected }
            .border(1.dp, PeeringColors.hairline, CardShape)
            .let { if (selected) it.border(1.5.dp, PeeringColors.accent, CardShape) else it }
            .padding(horizontal = 16.dp, vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Radio(selected)
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(title, style = PeeringText.subheadlineSemibold, color = PeeringColors.ink)
                if (badge != null) {
                    Spacer(Modifier.width(6.dp))
                    Text(
                        badge,
                        style = PeeringText.caption2.copy(fontSize = 10.sp, fontWeight = FontWeight.Bold),
                        color = PeeringColors.onInk,
                        modifier = Modifier.background(PeeringColors.ink, CircleShape).padding(horizontal = 7.dp, vertical = 2.dp),
                    )
                }
            }
            Text(detail, style = PeeringText.caption, color = PeeringColors.muted)
        }
        if (price != null) {
            Spacer(Modifier.width(8.dp))
            Column(horizontalAlignment = Alignment.End) {
                Text(price, style = PeeringText.display(size = 22f, tracking = -0.6f), color = PeeringColors.ink, textAlign = TextAlign.End)
                if (priceCaption != null) Text(priceCaption, style = PeeringText.caption2, color = PeeringColors.muted)
            }
        }
    }
}

@Composable
private fun Radio(selected: Boolean) {
    Icon(
        if (selected) AppIcons.checkCircleFilled else AppIcons.circle,
        null,
        tint = if (selected) PeeringColors.accent else Color.White.copy(alpha = 0.3f),
        modifier = Modifier.size(20.dp),
    )
}

