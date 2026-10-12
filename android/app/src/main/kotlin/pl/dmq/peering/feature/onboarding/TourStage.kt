package pl.dmq.peering.feature.onboarding

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.offset
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import pl.dmq.peering.ui.kit.FloatingChip
import pl.dmq.peering.ui.kit.FloatingChips
import pl.dmq.peering.ui.kit.MacDrawing
import pl.dmq.peering.ui.kit.MacMetrics
import pl.dmq.peering.ui.kit.PhoneDrawing
import pl.dmq.peering.ui.kit.PhoneMetrics

private const val PAIR_PHONE_SCREEN = 0.46f
private const val PAIR_OVERLAP = 0.14f
private const val MAC_LIFT = 0.035f

/** The device the tour holds up for [page], centred in the box it is given, with its chips hung on the box's edges. */
@Composable
internal fun TourStage(page: TourPage, modifier: Modifier = Modifier) {
    Box(modifier.fillMaxSize()) {
        AnimatedContent(
            targetState = page,
            transitionSpec = { fadeIn(tween(120)) togetherWith fadeOut(tween(120)) },
            label = "stage",
            contentKey = { it.step },
        ) { shown ->
            BoxWithConstraints(Modifier.fillMaxSize()) {
                if (shown.companion != null && shown.content is TourContent.Picture) {
                    ComputerAndPhone(shown.content.screenshot, shown.companion, maxWidth, maxHeight)
                } else {
                    PhoneAlone(shown.content, maxWidth, maxHeight)
                }
                FloatingChips(
                    shown.chips.map { FloatingChip(it.symbol, stringResource(it.title), it.atEnd, it.y) },
                )
            }
        }
    }
}

@Composable
private fun androidx.compose.foundation.layout.BoxScope.PhoneAlone(content: TourContent, width: Dp, height: Dp) {
    val byHeight = height / (1 + 2 * PhoneMetrics.ASPECT * PhoneMetrics.BEZEL)
    val byWidth = width / (PhoneMetrics.ASPECT * (1 + 2 * PhoneMetrics.BEZEL))
    val screenHeight = if (byHeight < byWidth) byHeight else byWidth
    PhoneDrawing(screenHeight * PhoneMetrics.ASPECT, Modifier.align(Alignment.Center)) { TourScreen(content) }
}

@Composable
private fun androidx.compose.foundation.layout.BoxScope.ComputerAndPhone(computer: Int, phone: Int, width: Dp, height: Dp) {
    val lid = 1 + 2 * MacMetrics.BEZEL
    val macWidth = lid * MacMetrics.BASE_OVERHANG
    val macHeight = 1 / MacMetrics.ASPECT + 2 * MacMetrics.BEZEL + lid * MacMetrics.BASE_HEIGHT
    val macColumn = macHeight + MAC_LIFT
    val phoneWidth = PAIR_PHONE_SCREEN * (1 + 2 * PhoneMetrics.BEZEL)
    val phoneHeight = PAIR_PHONE_SCREEN * (1 / PhoneMetrics.ASPECT + 2 * PhoneMetrics.BEZEL)
    val pairWidth = macWidth + phoneWidth - PAIR_OVERLAP
    val pairHeight = maxOf(macColumn, phoneHeight)
    val byHeight = height / (MacMetrics.ASPECT * pairHeight)
    val byWidth = width / (MacMetrics.ASPECT * pairWidth)
    val displayHeight = if (byHeight < byWidth) byHeight else byWidth
    val display = displayHeight * MacMetrics.ASPECT
    MacDrawing(
        display,
        Modifier
            .align(Alignment.Center)
            .offset(x = display * (-pairWidth / 2 + macWidth / 2), y = display * (pairHeight / 2 - macColumn + macHeight / 2)),
    ) { Picture(computer) }
    PhoneDrawing(
        display * PAIR_PHONE_SCREEN,
        Modifier
            .align(Alignment.Center)
            .offset(x = display * (pairWidth / 2 - phoneWidth / 2), y = display * (pairHeight / 2 - phoneHeight / 2)),
    ) { Picture(phone) }
}

@Composable
private fun TourScreen(content: TourContent) {
    when (content) {
        is TourContent.Picture -> Picture(content.screenshot)
        TourContent.Notification -> NotificationBanner()
        TourContent.Plans -> Box(Modifier.fillMaxSize())
    }
}

@Composable
internal fun Picture(resource: Int, modifier: Modifier = Modifier.fillMaxSize()) {
    Image(painterResource(resource), contentDescription = null, modifier = modifier, contentScale = ContentScale.Crop)
}
