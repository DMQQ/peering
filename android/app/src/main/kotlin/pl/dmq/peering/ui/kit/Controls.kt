package pl.dmq.peering.ui.kit

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import pl.dmq.peering.ui.theme.peeringShapes
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText

/** A settings-shaped card: a small title, its content 12 apart, and a tertiary footer. */
@Composable
fun ControlsCard(title: String, modifier: Modifier = Modifier, footer: String? = null, content: @Composable ColumnScope.() -> Unit) {
    Column(modifier.fillMaxWidth().cardBackground().padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text(
            title.uppercase(),
            style = PeeringText.caption2.copy(fontSize = 10.sp, fontWeight = FontWeight.SemiBold, letterSpacing = 1.1.sp),
            color = PeeringColors.muted,
            modifier = Modifier.semantics { heading() },
        )
        content()
        if (footer != null) Text(footer, style = PeeringText.caption, color = PeeringColors.tertiary)
    }
}

/** The 28 point glyph tile at the head of a row: 13 point glyph, rounded, [tint] at 0.14. */
@Composable
fun ControlIcon(icon: ImageVector, modifier: Modifier = Modifier, tint: Color = PeeringColors.ink) {
    Box(modifier.size(28.dp).background(tint.copy(alpha = 0.14f), peeringShapes.extraSmall), contentAlignment = Alignment.Center) {
        Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(16.dp))
    }
}

/** A tile, a title and whatever control sits at the trailing edge. */
@Composable
fun ControlRow(title: String, icon: ImageVector, modifier: Modifier = Modifier, control: (@Composable () -> Unit)? = null) {
    Row(modifier.fillMaxWidth().padding(vertical = 2.dp), verticalAlignment = Alignment.CenterVertically) {
        ControlIcon(icon)
        Spacer(Modifier.width(11.dp))
        Text(title, style = PeeringText.subheadlineMedium, color = PeeringColors.ink, modifier = Modifier.weight(1f))
        Spacer(Modifier.width(10.dp))
        control?.invoke()
    }
}

@Composable
fun ControlToggle(title: String, icon: ImageVector, checked: Boolean, onCheckedChange: (Boolean) -> Unit, modifier: Modifier = Modifier) {
    ControlRow(title, icon, modifier) { PeeringSwitch(checked, onCheckedChange) }
}

@Composable
fun ControlsDivider(modifier: Modifier = Modifier) {
    Box(modifier.fillMaxWidth().height(1.dp).background(Color.White.copy(alpha = 0.07f)))
}
