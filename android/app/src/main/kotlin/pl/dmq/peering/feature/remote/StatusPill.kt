package pl.dmq.peering.feature.remote

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import kotlin.math.roundToInt
import androidx.compose.ui.util.lerp
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.layout.layoutId
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.drawscope.clipPath
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.geometry.RoundRect
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.runtime.remember
import androidx.compose.runtime.getValue
import androidx.compose.runtime.derivedStateOf
import androidx.compose.animation.core.animateFloatAsState
import pl.dmq.peering.ui.kit.Motion
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import pl.dmq.peering.R
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.kit.blockTouches
import pl.dmq.peering.ui.kit.sessionSurface
import pl.dmq.peering.ui.kit.tappable
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText
import pl.dmq.peering.ui.theme.PillShape

/** What the pill shows about the session: the facts, then the state of the toggles its chips flip. */
data class StatusUi(
    val overlay: SessionOverlayState,
    val sourceTitle: String?,
    /** The number of tiles while a mosaic is on screen, else null. */
    val mosaicWindows: Int?,
    val darkened: Boolean,
    val fills: Boolean,
    val zoomPercent: Int?,
    val hubTabs: List<HubTab>,
)

/** What a tap on the pill's chips and buttons does. */
class StatusActions(
    val onLock: () -> Unit,
    val onToggleDark: () -> Unit,
    val onToggleFill: () -> Unit,
    val onResetZoom: () -> Unit,
    val onImmersive: () -> Unit,
    val onStepAway: () -> Unit,
    val onOpenHub: () -> Unit,
    val onQuit: () -> Unit,
)

/**
 * The status pill: closed it is the computer's name, the window on screen and the route in 56 dp; open it holds the
 * session's own controls in labelled rows. It grows from one to the other in place.
 */
@Composable
fun StatusPill(
    ui: StatusUi,
    actions: StatusActions,
    expanded: Boolean,
    onTap: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val progress = animateFloatAsState(if (expanded) 1f else 0f, Motion.spring(), label = "pill")
    val showCollapsed by remember(expanded) { derivedStateOf { !expanded || progress.value < 1f } }
    val showExpanded by remember(expanded) { derivedStateOf { expanded || progress.value > 0f } }
    val collapsedCorner = with(LocalDensity.current) { ChromeMetrics.pillCollapsedRadius.toPx() }
    val expandedCorner = with(LocalDensity.current) { ChromeMetrics.pillExpandedRadius.toPx() }
    val fill = PeeringColors.containerHigh
    val side = with(LocalDensity.current) { SIDE_BUTTON_SPACE.toPx() }
    Layout(
        content = {
            Box(Modifier.layoutId(COLLAPSED).graphicsLayer { alpha = (1f - progress.value * 2.2f).coerceIn(0f, 1f) }.blockTouches()) {
                if (showCollapsed) CollapsedPill(ui, onTap)
            }
            Box(Modifier.layoutId(EXPANDED).graphicsLayer { alpha = ((progress.value - 0.35f) / 0.65f).coerceIn(0f, 1f) }.blockTouches()) {
                if (showExpanded) ExpandedPill(ui, actions, onTap)
            }
        },
        modifier = modifier.drawWithContent {
            val inset = lerp(side, 0f, progress.value)
            val corner = lerp(collapsedCorner, expandedCorner, progress.value).coerceAtMost(size.height / 2f)
            val face = Path().apply {
                addRoundRect(RoundRect(inset, 0f, size.width - inset, size.height, CornerRadius(corner, corner)))
            }
            drawPath(face, fill)
            clipPath(face) { this@drawWithContent.drawContent() }
        },
    ) { measurables, constraints ->
        val p = progress.value
        val inset = lerp(side, 0f, p).roundToInt()
        val width = (constraints.maxWidth - inset * 2).coerceAtLeast(0)
        val closed = measurables.first { it.layoutId == COLLAPSED }.measure(Constraints.fixedWidth(width))
        val open = measurables.first { it.layoutId == EXPANDED }.measure(Constraints(minWidth = width, maxWidth = width))
        val height = lerp(closed.height.toFloat(), maxOf(open.height, closed.height).toFloat(), p).roundToInt()
        layout(constraints.maxWidth, height) {
            closed.place(inset, 0)
            open.place(inset, 0)
        }
    }
}

/** The room the lock and terminal buttons take on each side of the closed pill. */
internal val SIDE_BUTTON_SPACE = 61.dp

private const val COLLAPSED = "collapsed"
private const val EXPANDED = "expanded"

@Composable
private fun CollapsedPill(ui: StatusUi, onOpen: () -> Unit) {
    val name = ui.overlay.hostName ?: stringResource(R.string.remote_computer_fallback)
    Row(
        Modifier.fillMaxWidth().height(ChromeMetrics.pillHeight).tappable(onOpen).padding(start = 16.dp, end = 20.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(7.dp)) {
                StatusDot(ui.overlay, 6)
                Text(name, style = PeeringText.captionSemibold, color = PeeringColors.ink, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            Row(Modifier.padding(start = 13.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                val mosaicLabel = ui.mosaicWindows?.let { pluralStringResource(R.plurals.sources_windows, it, it) }
                val line = if (ui.overlay.reconnecting) stringResource(R.string.remote_reconnecting_short) else sourceLine(ui.sourceTitle, mosaicLabel)
                if (line != null) {
                    Text(
                        line,
                        style = PeeringText.caption2,
                        color = if (ui.overlay.reconnecting) PeeringColors.caution else PeeringColors.muted,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f, fill = false),
                    )
                }
                RouteChip(ui.overlay)
            }
        }
        Icon(AppIcons.expand, contentDescription = stringResource(R.string.remote_pill_open), tint = PeeringColors.tertiary, modifier = Modifier.size(16.dp))
    }
}

@Composable
private fun ExpandedPill(ui: StatusUi, actions: StatusActions, onClose: () -> Unit) {
    val name = ui.overlay.hostName ?: stringResource(R.string.remote_computer_fallback)
    Column(
        Modifier.fillMaxWidth().padding(start = 16.dp, end = 20.dp, top = 10.dp, bottom = 10.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Row(
            Modifier.fillMaxWidth().heightIn(min = 48.dp).tappable(onClose),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            StatusDot(ui.overlay, 7)
            Text(name, style = PeeringText.subheadlineSemibold, color = PeeringColors.ink, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
            RouteChip(ui.overlay)
        }
        StatusRows(ui, actions)
    }
}

@Composable
internal fun StatusDot(overlay: SessionOverlayState, size: Int) {
    val color = when (RouteHealth.of(overlay)) {
        RouteHealth.GOOD -> PeeringColors.added
        RouteHealth.DEGRADED -> PeeringColors.caution
        RouteHealth.BROKEN -> PeeringColors.danger
        RouteHealth.UNKNOWN -> PeeringColors.muted
    }
    val description = stringResource(
        when (RouteHealth.of(overlay)) {
            RouteHealth.GOOD -> R.string.remote_dot_connected
            RouteHealth.DEGRADED -> R.string.remote_dot_degraded
            RouteHealth.BROKEN -> R.string.remote_dot_broken
            RouteHealth.UNKNOWN -> R.string.remote_dot_waiting
        },
    )
    Box(Modifier.size(size.dp).clip(PillShape).background(color).semantics { contentDescription = description })
}

/** The route as a small capsule of capitals: LAN, RELAY or DIRECT. */
@Composable
internal fun RouteChip(overlay: SessionOverlayState) {
    val path = overlay.path ?: return
    Text(
        stringResource(path.labelRes()).uppercase(),
        style = PeeringText.caption2.copy(fontWeight = FontWeight.Bold, letterSpacing = 0.5.sp),
        color = PeeringColors.muted,
        modifier = Modifier.clip(PillShape).background(PeeringColors.surface).padding(horizontal = 7.dp, vertical = 3.dp),
    )
}

/** One chip of a pill row: a glyph and a word. The row gives every chip the same share of its width. */
data class PillChipSpec(
    val label: String,
    val icon: ImageVector?,
    val onClick: () -> Unit,
    val destructive: Boolean = false,
    val tint: Color? = null,
)

@Composable
internal fun PillChip(spec: PillChipSpec, modifier: Modifier = Modifier) {
    val fill = if (spec.destructive) PeeringColors.danger else PeeringColors.ink.copy(alpha = 0.12f)
    val content = spec.tint ?: if (spec.destructive) PeeringColors.onInk else PeeringColors.ink
    Row(
        modifier = modifier
            .height(30.dp)
            .clip(PillShape)
            .background(fill)
            .tappable(spec.onClick)
            .padding(horizontal = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(5.dp, Alignment.CenterHorizontally),
    ) {
        spec.icon?.let { Icon(it, contentDescription = null, tint = content, modifier = Modifier.size(16.dp)) }
        Text(spec.label, style = PeeringText.caption.copy(fontWeight = FontWeight.Medium), color = content, maxLines = 1, softWrap = false)
    }
}

/** A row of the expanded pill: the section's glyph and name at the start, its chips after it in equal shares. */
@Composable
internal fun PillRow(title: String, icon: ImageVector, chips: List<PillChipSpec>) {
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
        Row(Modifier.width(ROW_LABEL_WIDTH), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(7.dp)) {
            Icon(icon, contentDescription = null, tint = PeeringColors.muted, modifier = Modifier.size(14.dp))
            Text(title, style = PeeringText.captionSemibold, color = PeeringColors.muted, maxLines = 1)
        }
        Row(Modifier.weight(1f), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            chips.forEach { PillChip(it, Modifier.weight(1f)) }
        }
    }
}

private val ROW_LABEL_WIDTH = 74.dp
