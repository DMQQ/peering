package pl.dmq.peering.feature.onboarding

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.CompositingStrategy
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.res.stringResource
import pl.dmq.peering.R
import pl.dmq.peering.ui.kit.FloatingChip
import pl.dmq.peering.ui.kit.FloatingChips
import pl.dmq.peering.ui.kit.PhoneDrawing
import pl.dmq.peering.ui.kit.PhoneMetrics
import pl.dmq.peering.ui.kit.Symbols

/** The plans page's picture: the app's own screen in the tour's phone, rising out of the bottom edge, with what the paid plans add around it. */
@Composable
internal fun PlansHero(modifier: Modifier = Modifier) {
    BoxWithConstraints(modifier.clipToBounds()) {
        Box(
            Modifier
                .fillMaxSize()
                .graphicsLayer { compositingStrategy = CompositingStrategy.Offscreen }
                .drawWithContent {
                    drawContent()
                    drawRect(
                        brush = Brush.verticalGradient(0.4f to Color.Black, 1f to Color.Transparent),
                        blendMode = BlendMode.DstIn,
                    )
                },
        ) {
            PhoneDrawing(this@BoxWithConstraints.maxHeight * 1.5f * PhoneMetrics.ASPECT, Modifier.align(Alignment.TopCenter)) {
                Picture(R.drawable.tour_connect)
            }
        }
        FloatingChips(
            listOf(
                FloatingChip(Symbols.infinity, stringResource(R.string.chip_unlimited_away), false, 0.2f),
                FloatingChip(Symbols.sparkles, stringResource(R.string.chip_sharpest), true, 0.42f),
                FloatingChip(Symbols.globe, stringResource(R.string.chip_any_network), false, 0.7f),
            ),
        )
    }
}
