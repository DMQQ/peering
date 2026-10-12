package pl.dmq.peering.feature.onboarding

import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.painterResource
import pl.dmq.peering.R
import pl.dmq.peering.ui.kit.FloatingChip
import pl.dmq.peering.ui.kit.FloatingChips
import pl.dmq.peering.ui.kit.PhoneDrawing
import pl.dmq.peering.ui.kit.PhoneMetrics
import pl.dmq.peering.ui.kit.Symbols
import androidx.compose.foundation.background
import androidx.compose.ui.res.stringResource

private const val OVERLAP = 0.3f
private const val DROP = 0.07f
private const val BLEED = 1.1f

/** The landing's picture: remote control in front, the agents list behind it dimmed, and three reasons it is safe to try hung around both. */
@Composable
internal fun WelcomeHero(modifier: Modifier = Modifier) {
    BoxWithConstraints(modifier) {
        val bodyWidthPerScreen = 1 + 2 * PhoneMetrics.BEZEL
        val bodyHeightPerScreen = 1 / PhoneMetrics.ASPECT + 2 * PhoneMetrics.BEZEL
        val byWidth = maxWidth / (bodyWidthPerScreen * (2 - OVERLAP))
        val byHeight = maxHeight / (bodyHeightPerScreen * (1 + DROP))
        val screenWidth = (if (byWidth < byHeight) byWidth else byHeight) * 0.92f
        val bodyWidth = screenWidth * bodyWidthPerScreen
        val bodyHeight = screenWidth * bodyHeightPerScreen
        Box(Modifier.align(Alignment.Center).size(bodyWidth * (2 - OVERLAP), bodyHeight * (1 + DROP)).scale(BLEED)) {
            PhoneDrawing(
                screenWidth,
                Modifier.offset(y = bodyHeight * DROP).rotate(-6f),
            ) {
                Image(painterResource(R.drawable.tour_agents), null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
                Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.3f)))
            }
            PhoneDrawing(
                screenWidth,
                Modifier.offset(x = bodyWidth * (1 - OVERLAP)).rotate(4f),
            ) {
                Image(painterResource(R.drawable.tour_controls), null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
            }
        }
        FloatingChips(
            listOf(
                FloatingChip(Symbols.lockShield, stringResource(R.string.chip_encrypted), false, 0.06f),
                FloatingChip(Symbols.personCropCircleBadgeXmark, stringResource(R.string.chip_no_account), true, 0.5f),
                FloatingChip(Symbols.wifi, stringResource(R.string.chip_free_own_network), false, 0.76f),
            ),
        )
    }
}
