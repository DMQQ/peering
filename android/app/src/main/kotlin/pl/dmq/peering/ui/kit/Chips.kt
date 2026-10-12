package pl.dmq.peering.ui.kit

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText

/** A small pill on the surface fill with a glyph and a label, like "Connect by address". */
@Composable
fun CapsuleChip(title: String, icon: ImageVector, onClick: () -> Unit, modifier: Modifier = Modifier) {
    Row(
        modifier = modifier
            .pressable(onClick)
            .clip(CircleShape)
            .background(PeeringColors.surface)
            .padding(horizontal = 10.dp, vertical = 5.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(icon, contentDescription = null, tint = PeeringColors.muted, modifier = Modifier.size(12.dp))
        Spacer(Modifier.width(5.dp))
        Text(title, style = PeeringText.caption2.copy(fontWeight = FontWeight.SemiBold), color = PeeringColors.muted)
    }
}

/** A round glyph button on the surface fill, 28 across by default (the refresh button beside Nearby). */
@Composable
fun CircleIconButton(icon: ImageVector, description: String, onClick: () -> Unit, modifier: Modifier = Modifier, size: Dp = 28.dp) {
    Box(
        modifier = modifier
            .size(size)
            .pressable(onClick)
            .clip(CircleShape)
            .background(PeeringColors.surface),
        contentAlignment = Alignment.Center,
    ) {
        Icon(icon, contentDescription = description, tint = PeeringColors.muted, modifier = Modifier.size(size * 0.5f))
    }
}
