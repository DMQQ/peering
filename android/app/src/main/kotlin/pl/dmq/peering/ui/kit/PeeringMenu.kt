package pl.dmq.peering.ui.kit

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Popup
import androidx.compose.ui.window.PopupProperties
import pl.dmq.peering.ui.theme.ContinuousShape
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText

private val menuShape = ContinuousShape(18.dp)

/** A context menu drawn as the iPhone's is: a dark rounded panel dropped from its anchor. Call it inside the anchor's box. */
@Composable
fun PeeringMenu(expanded: Boolean, onDismiss: () -> Unit, content: @Composable ColumnScope.() -> Unit) {
    if (!expanded) return
    val drop = with(LocalDensity.current) { 38.dp.roundToPx() }
    Popup(alignment = Alignment.TopEnd, offset = IntOffset(0, drop), onDismissRequest = onDismiss, properties = PopupProperties(focusable = true)) {
        Column(
            Modifier
                .shadow(18.dp, menuShape, ambientColor = androidx.compose.ui.graphics.Color.Black, spotColor = androidx.compose.ui.graphics.Color.Black)
                .glassSurface(menuShape)
                .widthIn(min = 220.dp)
                .padding(vertical = 6.dp),
            content = content,
        )
    }
}

@Composable
fun MenuItem(title: String, icon: ImageVector, onClick: () -> Unit, modifier: Modifier = Modifier, destructive: Boolean = false, enabled: Boolean = true) {
    val tint = if (destructive) PeeringColors.danger else PeeringColors.ink
    Row(
        modifier.alpha(if (enabled) 1f else 0.4f).pressable(onClick, enabled = enabled, scale = 0.98f).padding(horizontal = 16.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(title, style = PeeringText.body, color = tint, modifier = Modifier.weight(1f))
        Spacer(Modifier.width(16.dp))
        Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(20.dp))
    }
}
