package pl.dmq.peering.ui.kit

import androidx.compose.foundation.background
import androidx.compose.runtime.Composable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.unit.dp
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.peeringShapes

val CardShape: Shape = peeringShapes.large
val RowShape: Shape = peeringShapes.medium

/** True inside the session screen, where outlines are dropped for tonal fills; everywhere else controls are outlined. */
val LocalBorderless = staticCompositionLocalOf { false }

/** Material's filled card: a flat tonal surface with no outline, the same wherever it sits. */
fun Modifier.tonalCard(shape: Shape): Modifier = clip(shape).background(PeeringColors.containerHigh)

/** A card is a flat tonal surface. */
@Composable
fun Modifier.cardBackground(): Modifier = tonalCard(CardShape)

/** A row resting on a card: the one filled surface, clipped so a ripple on it keeps its corners. */
fun Modifier.rowSurface(): Modifier = clip(RowShape).background(PeeringColors.surface)

/** A pill or panel for things floating over artwork: a flat tonal surface. */
fun Modifier.chipSurface(shape: Shape): Modifier = tonalCard(shape)

/** The surface of session chrome over the picture: a tonal fill and no outline, groups told apart by spacing. */
fun Modifier.sessionSurface(shape: Shape): Modifier = clip(shape).background(PeeringColors.containerHigh)

/** A card on the agents and terminals pages. */
fun Modifier.hubCardSurface(shape: Shape): Modifier = tonalCard(shape)
