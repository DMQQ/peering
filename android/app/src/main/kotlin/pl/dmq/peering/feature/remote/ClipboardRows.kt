package pl.dmq.peering.feature.remote

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.kit.rowSurface
import pl.dmq.peering.ui.kit.tappable
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText
import pl.dmq.peering.ui.theme.PillShape
import pl.dmq.peering.ui.theme.peeringShapes

@Composable
internal fun ClipboardRow(
    icon: ImageVector,
    title: String,
    detail: String,
    empty: Boolean,
    confirmed: Boolean,
    actions: @Composable () -> Unit,
) {
    Column(Modifier.fillMaxWidth().rowSurface().padding(10.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Row(horizontalArrangement = Arrangement.spacedBy(11.dp)) {
            ClipboardIconTile(icon)
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    Text(title, style = PeeringText.subheadlineSemibold, color = PeeringColors.ink)
                    if (confirmed) Icon(AppIcons.check, contentDescription = null, tint = PeeringColors.accent, modifier = Modifier.size(14.dp))
                }
                Text(
                    detail,
                    style = PeeringText.caption,
                    color = if (empty) PeeringColors.tertiary else PeeringColors.muted,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.End)) { actions() }
    }
}

@Composable
internal fun ClipboardIconTile(icon: ImageVector) {
    Box(
        Modifier.size(28.dp).clip(peeringShapes.extraSmall).background(PeeringColors.ink.copy(alpha = 0.14f)),
        contentAlignment = Alignment.Center,
    ) { Icon(icon, contentDescription = null, tint = PeeringColors.ink, modifier = Modifier.size(16.dp)) }
}

@Composable
internal fun ClipAction(title: String, prominent: Boolean = false, enabled: Boolean, onClick: () -> Unit) {
    Text(
        title,
        style = PeeringText.subheadline.copy(fontWeight = if (prominent) FontWeight.SemiBold else FontWeight.Medium),
        color = if (prominent) PeeringColors.onInk else PeeringColors.ink,
        maxLines = 1,
        modifier = Modifier
            .alpha(if (enabled) 1f else 0.4f)
            .clip(PillShape)
            .background(if (prominent) PeeringColors.ink else PeeringColors.ink.copy(alpha = 0.12f))
            .tappable(onClick, enabled = enabled)
            .padding(horizontal = 12.dp, vertical = 7.dp),
    )
}
