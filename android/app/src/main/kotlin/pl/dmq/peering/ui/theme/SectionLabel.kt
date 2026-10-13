package pl.dmq.peering.ui.theme

import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/** A card section's name as Controls.sectionLabel draws it: a 14 point glyph and a 12 point semibold label tracked 0.2, secondary. */
@Composable
fun SectionLabel(text: String, icon: ImageVector, modifier: Modifier = Modifier) {
    Row(modifier = modifier.semantics { heading() }, verticalAlignment = Alignment.CenterVertically) {
        Icon(icon, contentDescription = null, tint = PeeringColors.muted, modifier = Modifier.size(14.dp))
        Spacer(Modifier.width(7.dp))
        Text(
            text = text,
            style = PeeringText.caption.copy(fontWeight = FontWeight.SemiBold, letterSpacing = 0.2.sp),
            color = PeeringColors.muted,
        )
    }
}
