package pl.dmq.peering.ui.kit

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import pl.dmq.peering.ui.theme.ContinuousShape
import pl.dmq.peering.ui.theme.PeeringColors

val CardShape = ContinuousShape(24.dp)
val RowShape = ContinuousShape(14.dp)

private val cardEdge = Brush.verticalGradient(listOf(Color.White.copy(alpha = 0.20f), Color.White.copy(alpha = 0.05f)))
private val rowFill = Brush.verticalGradient(listOf(Color.White.copy(alpha = 0.09f), Color.White.copy(alpha = 0.045f)))
private val glassFill = Brush.verticalGradient(listOf(Color.White.copy(alpha = 0.13f), Color.White.copy(alpha = 0.06f)))
private val glassEdge = Brush.verticalGradient(listOf(Color.White.copy(alpha = 0.22f), Color.White.copy(alpha = 0.06f)))

/** iOS cardBackground: radius 24, no fill, a one point stroke fading from 0.20 to 0.05 white. */
fun Modifier.cardBackground(): Modifier = border(1.dp, cardEdge, CardShape)

/** iOS rowSurface: radius 14, a faint top-lit fill and a 0.07 white stroke. */
fun Modifier.rowSurface(): Modifier = clip(RowShape)
    .background(rowFill)
    .border(1.dp, Color.White.copy(alpha = 0.07f), RowShape)

/** The Liquid Glass stand-in: dark, a little lit from above, edged. There is no blur behind it; the stage under it is near black. */
fun Modifier.glassSurface(shape: androidx.compose.ui.graphics.Shape): Modifier = this
    .clip(shape)
    .background(PeeringColors.backdrop.copy(alpha = 0.72f))
    .background(glassFill)
    .border(1.dp, glassEdge, shape)
