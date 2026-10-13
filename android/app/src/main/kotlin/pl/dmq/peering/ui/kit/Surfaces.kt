package pl.dmq.peering.ui.kit

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.runtime.Composable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.unit.dp
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.peeringShapes

val CardShape: Shape = peeringShapes.large
val RowShape: Shape = peeringShapes.medium

/** True inside the session screen, where outlines are dropped for tonal fills; everywhere else controls are outlined. */
val LocalBorderless = staticCompositionLocalOf { false }

/** A card is outlined and never filled, except in the session screen where it is a tonal surface. */
@Composable
fun Modifier.cardBackground(): Modifier =
    if (LocalBorderless.current) clip(CardShape).background(PeeringColors.containerHigh) else border(1.dp, PeeringColors.hairline, CardShape)

/** A row resting on a card: the one filled surface, clipped so a ripple on it keeps its corners. */
fun Modifier.rowSurface(): Modifier = clip(RowShape).background(PeeringColors.surface)

/** A raised, outlined pill or panel for things floating over artwork. */
fun Modifier.chipSurface(shape: Shape): Modifier = clip(shape)
    .background(PeeringColors.containerHigh)
    .border(1.dp, PeeringColors.outline, shape)

/** The surface of session chrome over the picture: a tonal fill and no outline, groups told apart by spacing. */
fun Modifier.sessionSurface(shape: Shape): Modifier = clip(shape).background(PeeringColors.containerHigh)

private val hubOutline = Brush.verticalGradient(listOf(Color.White.copy(alpha = 0.18f), Color.White.copy(alpha = 0.05f)))

/** A card on the agents and terminals pages: a fading outline and no fill, so both pages sit on the backdrop alike, as on the iPhone. */
fun Modifier.hubCardSurface(shape: Shape): Modifier = clip(shape).border(1.dp, hubOutline, shape)
