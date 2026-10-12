package pl.dmq.peering.ui.theme

import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/** A card section's name: a small glyph and a sentence-case label, never an all-caps eyebrow. */
@Composable
fun SectionLabel(text: String, icon: ImageVector, modifier: Modifier = Modifier) {
    Row(modifier = modifier.semantics { heading() }, verticalAlignment = Alignment.CenterVertically) {
        Icon(icon, contentDescription = null, tint = PeeringColors.muted, modifier = Modifier.size(16.dp))
        Spacer(Modifier.width(8.dp))
        Text(text = text, style = MaterialTheme.typography.labelMedium.copy(fontSize = 13.sp), color = PeeringColors.muted)
    }
}
