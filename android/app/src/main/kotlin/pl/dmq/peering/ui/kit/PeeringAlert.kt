package pl.dmq.peering.ui.kit

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import pl.dmq.peering.ui.theme.ContinuousShape
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText

/** The iOS 26 alert: a rounded dark card with a centred title and message and two capsule buttons. */
@Composable
fun PeeringAlert(
    title: String,
    message: String,
    confirm: String,
    onConfirm: () -> Unit,
    cancel: String,
    onCancel: () -> Unit,
    destructive: Boolean = false,
) {
    Dialog(onDismissRequest = onCancel) {
        val shape = ContinuousShape(34.dp)
        Column(
            Modifier
                .width(300.dp)
                .background(PeeringColors.sheet, shape)
                .border(1.dp, Color.White.copy(alpha = 0.10f), shape)
                .padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Text(title, style = PeeringText.headline, color = PeeringColors.ink, textAlign = TextAlign.Center)
            Text(message, style = PeeringText.footnote, color = PeeringColors.muted, textAlign = TextAlign.Center)
            Row(Modifier.fillMaxWidth().padding(top = 12.dp), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                AlertButton(cancel, onCancel, PeeringColors.ink, Modifier.weight(1f))
                AlertButton(confirm, onConfirm, if (destructive) PeeringColors.danger else PeeringColors.ink, Modifier.weight(1f))
            }
        }
    }
}

@Composable
private fun AlertButton(title: String, onClick: () -> Unit, tint: Color, modifier: Modifier) {
    Box(
        modifier.height(48.dp).pressable(onClick, scale = 0.96f).background(Color.White.copy(alpha = 0.10f), CircleShape),
        contentAlignment = Alignment.Center,
    ) {
        Text(title, style = PeeringText.body.copy(fontWeight = FontWeight.Medium), color = tint)
    }
}
