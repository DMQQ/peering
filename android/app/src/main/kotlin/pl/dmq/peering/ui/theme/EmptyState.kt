package pl.dmq.peering.ui.theme

import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R

/** Centred glyph (or the mascot), a name, one sentence, and optionally the action that fixes it. */
@Composable
fun EmptyState(
    icon: ImageVector?,
    title: String,
    body: String,
    modifier: Modifier = Modifier,
    action: (@Composable () -> Unit)? = null,
    mascot: Boolean = false,
) {
    Column(
        modifier = modifier.fillMaxWidth(),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        if (mascot) {
            Image(painterResource(R.drawable.pears), contentDescription = null, modifier = Modifier.size(width = 96.dp, height = 72.dp))
        } else if (icon != null) {
            IconTile(icon, size = 52.dp)
        }
        Text(title, style = MaterialTheme.typography.titleMedium, color = PeeringColors.ink, textAlign = TextAlign.Center)
        Text(body, style = MaterialTheme.typography.bodySmall, color = PeeringColors.muted, textAlign = TextAlign.Center)
        if (action != null) action()
    }
}
