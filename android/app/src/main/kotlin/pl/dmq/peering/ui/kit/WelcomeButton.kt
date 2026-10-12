package pl.dmq.peering.ui.kit

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText

/** The first-run and paywall button: a white capsule 54 points tall with a bold 17 point black label (WelcomeView.swift, WelcomePrimaryButton). */
@Composable
fun WelcomePrimaryButton(title: String, onClick: () -> Unit, modifier: Modifier = Modifier, enabled: Boolean = true) {
    Box(
        modifier
            .fillMaxWidth()
            .height(54.dp)
            .pressable(onClick, enabled = enabled)
            .alpha(if (enabled) 1f else 0.4f)
            .clip(CircleShape)
            .background(PeeringColors.ink),
        contentAlignment = Alignment.Center,
    ) {
        Text(title, style = PeeringText.headline.copy(fontWeight = FontWeight.Bold), color = PeeringColors.onInk)
    }
}
