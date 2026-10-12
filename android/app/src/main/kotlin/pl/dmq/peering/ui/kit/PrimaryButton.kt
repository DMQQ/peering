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
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText

/** The one filled control on a screen: a white capsule with a black label, shrinking on press. 54 tall as the tour and paywall draw it. */
@Composable
fun PrimaryButton(
    title: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    height: Dp = 54.dp,
) {
    Box(
        modifier = modifier
            .fillMaxWidth()
            .height(height)
            .pressable(onClick, enabled = enabled, scale = 0.965f, dim = 0.86f)
            .clip(CircleShape)
            .background(if (enabled) PeeringColors.ink else Color.White.copy(alpha = 0.16f)),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            text = title,
            style = PeeringText.headline.copy(fontWeight = FontWeight.Bold),
            color = if (enabled) PeeringColors.onInk else Color.White.copy(alpha = 0.55f),
        )
    }
}
