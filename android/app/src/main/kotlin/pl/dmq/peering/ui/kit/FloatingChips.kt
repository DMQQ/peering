package pl.dmq.peering.ui.kit

import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText
import pl.dmq.peering.ui.theme.PillShape

/** [y] is a fraction of the field's height, measured to the chip's top edge. */
data class FloatingChip(val symbol: ImageVector, val title: String, val atEnd: Boolean, val y: Float)

/** Chips hung on the edges of the box they fill. They sit still: the page's crossfade is the only motion they get. */
@Composable
fun FloatingChips(chips: List<FloatingChip>, modifier: Modifier = Modifier) {
    BoxWithConstraints(modifier.fillMaxSize()) {
        chips.forEach { chip ->
            Row(
                modifier = Modifier
                    .align(if (chip.atEnd) Alignment.TopEnd else Alignment.TopStart)
                    .offset(y = maxHeight * chip.y)
                    .chipSurface(PillShape)
                    .padding(horizontal = 12.dp, vertical = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(chip.symbol, contentDescription = null, tint = PeeringColors.ink, modifier = Modifier.size(15.dp))
                Spacer(Modifier.width(6.dp))
                Text(chip.title, style = PeeringText.captionSemibold.copy(fontWeight = FontWeight.SemiBold), color = PeeringColors.ink, maxLines = 1, softWrap = false)
            }
        }
    }
}
