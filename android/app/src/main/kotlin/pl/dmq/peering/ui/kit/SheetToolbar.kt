package pl.dmq.peering.ui.kit

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText

/** The bar atop a sheet: a glass Cancel capsule and, when the sheet edits something, a confirm capsule beside it. */
@Composable
fun SheetToolbar(
    cancel: String,
    onCancel: () -> Unit,
    modifier: Modifier = Modifier,
    title: String? = null,
    confirm: String? = null,
    canConfirm: Boolean = true,
    onConfirm: () -> Unit = {},
) {
    Box(modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 16.dp), contentAlignment = Alignment.Center) {
        if (title != null) Text(title, style = PeeringText.headline, color = PeeringColors.ink)
        Row(
            Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(10.dp, Alignment.End),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            ToolbarCapsule(cancel, onCancel, PeeringColors.accent, FontWeight.Normal, true)
            if (confirm != null) ToolbarCapsule(confirm, onConfirm, PeeringColors.accent, FontWeight.SemiBold, canConfirm)
        }
    }
}

@Composable
private fun ToolbarCapsule(title: String, onClick: () -> Unit, tint: androidx.compose.ui.graphics.Color, weight: FontWeight, enabled: Boolean) {
    Row(
        modifier = Modifier
            .height(41.dp)
            .pressable(onClick, enabled = enabled, scale = 0.96f)
            .glassSurface(CircleShape)
            .padding(horizontal = 16.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(title, style = PeeringText.body.copy(fontWeight = weight), color = if (enabled) tint else PeeringColors.tertiary)
    }
}
