package pl.dmq.peering.ui.kit

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.unit.dp
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.peeringShapes

val CardShape: Shape = peeringShapes.large
val RowShape: Shape = peeringShapes.medium

/** A card is outlined and never filled: a one point stroke and nothing behind it. */
fun Modifier.cardBackground(): Modifier = border(1.dp, PeeringColors.hairline, CardShape)

/** A row resting on a card: the one filled surface, clipped so a ripple on it keeps its corners. */
fun Modifier.rowSurface(): Modifier = clip(RowShape).background(PeeringColors.surface)

/** A raised, outlined pill or panel for things floating over artwork. */
fun Modifier.chipSurface(shape: Shape): Modifier = clip(shape)
    .background(PeeringColors.containerHigh)
    .border(1.dp, PeeringColors.outline, shape)
