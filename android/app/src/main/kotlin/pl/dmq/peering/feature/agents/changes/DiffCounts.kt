package pl.dmq.peering.feature.agents.changes

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import java.text.NumberFormat
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText

/** +N and -M in the diff colours, the pair every file row and header shows. A side with nothing is left out. */
@Composable
fun DiffCounts(added: Int, removed: Int, modifier: Modifier = Modifier, size: Int = 11) {
    val style = PeeringText.caption.copy(fontSize = size.sp, fontWeight = FontWeight.SemiBold, fontFamily = FontFamily.Monospace)
    Row(modifier, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        if (added > 0) Text("+" + NumberFormat.getIntegerInstance().format(added), style = style, color = PeeringColors.added)
        if (removed > 0) Text("-" + NumberFormat.getIntegerInstance().format(removed), style = style, color = PeeringColors.danger)
    }
}
