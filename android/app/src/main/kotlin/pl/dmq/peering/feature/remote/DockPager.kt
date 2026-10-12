package pl.dmq.peering.feature.remote

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.PagerDefaults
import androidx.compose.foundation.pager.PagerSnapDistance
import androidx.compose.foundation.pager.PagerState
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.unit.dp
import pl.dmq.peering.ui.theme.PeeringColors

/**
 * The dock as pages of equal slots that snap, one page per fling. [paging] is laid out by [DockPaging]; when the
 * application's chords appear the pager glides to the page they start on.
 */
@Composable
internal fun DockPager(
    paging: DockPages,
    state: PagerState,
    control: @Composable (DockControl, Modifier) -> Unit,
    onChord: (QuickAction) -> Unit,
    perPage: Int,
    modifier: Modifier = Modifier,
) {
    HorizontalPager(
        state = state,
        modifier = modifier.fillMaxWidth().height(ChromeMetrics.dockSlotHeight),
        flingBehavior = PagerDefaults.flingBehavior(state, pagerSnapDistance = PagerSnapDistance.atMost(1)),
        key = { it },
    ) { index ->
        val slots = paging.pages[index]
        Row(Modifier.fillMaxSize()) {
            repeat(perPage) { position ->
                val slot = slots.getOrNull(position)
                Box(Modifier.weight(1f).fillMaxSize().padding(horizontal = 1.dp).groupEdge(slot != null && slot.startsGroup && position > 0)) {
                    if (slot?.control != null) control(slot.control, Modifier.fillMaxSize())
                    if (slot?.action != null) ChordRailButton(slot.action.chord, slot.action.label, { onChord(slot.action) }, Modifier.fillMaxSize())
                }
            }
        }
    }
}

@Composable
internal fun rememberDockPagerState(paging: DockPages, applicationId: String?): PagerState {
    val pageCount = rememberUpdatedState(paging.pages.size)
    val state = rememberPagerState { pageCount.value }
    val applicationPage = rememberUpdatedState(paging.pageOfApplication())
    LaunchedEffect(applicationId) {
        applicationPage.value?.let { state.animateScrollToPage(it) }
    }
    return state
}

/** Tiny dots for where the pager is: drawn, not composed, so a swipe does not recompose the dock. */
@Composable
internal fun DockPageDots(state: PagerState, count: Int, modifier: Modifier = Modifier) {
    val color = PeeringColors.muted
    val active = PeeringColors.ink
    val width = remember(count) { (DOT_SIZE + DOT_GAP) * count - DOT_GAP }
    Box(
        modifier
            .width(width)
            .height(DOT_SIZE)
            .drawBehind {
                val size = DOT_SIZE.toPx()
                val step = size + DOT_GAP.toPx()
                val position = state.currentPage + state.currentPageOffsetFraction
                repeat(count) { index ->
                    val near = (1f - kotlin.math.abs(index - position)).coerceIn(0f, 1f)
                    drawCircle(if (near > 0.5f) active else color, size / 2f, Offset(index * step + size / 2f, size / 2f))
                }
            },
    )
}

private fun Modifier.groupEdge(visible: Boolean): Modifier =
    if (!visible) this else drawBehind {
        drawLine(
            PeeringColors.muted.copy(alpha = 0.35f), Offset(0f, size.height * 0.3f), Offset(0f, size.height * 0.7f), 1.dp.toPx(),
        )
    }

private val DOT_SIZE = 6.dp
private val DOT_GAP = 6.dp
