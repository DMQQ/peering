package pl.dmq.peering.feature.remote

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import pl.dmq.peering.ui.kit.blockTouches
import pl.dmq.peering.ui.kit.chipSurface
import pl.dmq.peering.ui.kit.tappable
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText
import pl.dmq.peering.ui.theme.PillShape

/** A tap that answers in the hand: the work happens on the other machine, so the phone says it was heard. */
@Composable
private fun Modifier.heardTap(enabled: Boolean = true, onClick: () -> Unit): Modifier {
    val haptics = LocalHapticFeedback.current
    return tappable(
        {
            haptics.performHapticFeedback(HapticFeedbackType.TextHandleMove)
            onClick()
        },
        enabled = enabled,
    )
}

/** An icon over a one line label in a stadium cell, the unit of the dock and of the rails. The selected one fills with the blue. */
@Composable
fun RailButton(
    icon: ImageVector,
    label: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    selected: Boolean = false,
    enabled: Boolean = true,
) {
    Column(
        modifier = modifier
            .widthIn(min = ChromeMetrics.panelWidth - 8.dp)
            .height(ChromeMetrics.buttonHeight)
            .clip(PillShape)
            .background(if (selected) PeeringColors.accent else Color.Transparent)
            .alpha(if (enabled) 1f else 0.45f)
            .heardTap(enabled, onClick)
            .semantics { this.selected = selected; contentDescription = label },
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(2.dp, Alignment.CenterVertically),
    ) {
        Icon(icon, contentDescription = null, tint = PeeringColors.ink, modifier = Modifier.size(22.dp))
        Text(
            label,
            style = PeeringText.caption2.copy(fontSize = 9.sp, fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal),
            color = if (selected) PeeringColors.ink else PeeringColors.muted,
            maxLines = 1,
            overflow = TextOverflow.Clip,
        )
    }
}

/** The chord is the mark, with the word under it: faster to scan than a glyph, and the same as on a keyboard. */
@Composable
fun ChordRailButton(chord: String, label: String, onClick: () -> Unit, modifier: Modifier = Modifier) {
    Column(
        modifier = modifier
            .widthIn(min = ChromeMetrics.panelWidth - 8.dp)
            .height(ChromeMetrics.buttonHeight)
            .clip(PillShape)
            .heardTap(onClick = onClick)
            .semantics { contentDescription = label },
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(2.dp, Alignment.CenterVertically),
    ) {
        Text(chord, style = PeeringText.subheadlineSemibold.copy(fontSize = 16.sp), color = PeeringColors.ink, maxLines = 1)
        Text(label, style = PeeringText.caption2.copy(fontSize = 9.sp), color = PeeringColors.muted, maxLines = 1)
    }
}

/** A round glass key with a glyph and a word under it: Back and Enter beside the joystick. */
@Composable
fun QuickKey(icon: ImageVector, label: String, size: Dp, onClick: () -> Unit, modifier: Modifier = Modifier) {
    Box(
        modifier = modifier
            .size(size)
            .chipSurface(PillShape)
            .heardTap(onClick = onClick)
            .semantics { contentDescription = label },
        contentAlignment = Alignment.Center,
    ) {
        Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(1.dp)) {
            Icon(icon, contentDescription = null, tint = PeeringColors.ink, modifier = Modifier.size(size / 3 + 4.dp))
            Text(label, style = PeeringText.caption2.copy(fontSize = 9.sp, fontWeight = FontWeight.SemiBold), color = PeeringColors.ink, maxLines = 1)
        }
    }
}

/** A round glass button with only a glyph: the lock and terminal buttons that flank the status pill. */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun CircleGlassButton(
    icon: ImageVector,
    label: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    tint: Color = PeeringColors.ink,
    onLongClick: (() -> Unit)? = null,
) {
    val base = modifier.size(ChromeMetrics.circleButton).chipSurface(PillShape)
    Box(
        modifier = (if (onLongClick == null) base.tappable(onClick) else base.combinedClickable(onClick = onClick, onLongClick = onLongClick))
            .semantics { contentDescription = label; role = Role.Button },
        contentAlignment = Alignment.Center,
    ) {
        Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(22.dp))
    }
}

/** The rail's own stadium, 54 wide, holding a column of rail buttons that scrolls when the screen is short. */
@Composable
fun ControlRail(modifier: Modifier = Modifier, content: @Composable () -> Unit) {
    Column(
        modifier = modifier
            .width(ChromeMetrics.panelWidth)
            .chipSurface(PillShape)
            .blockTouches()
            .verticalScroll(rememberScrollState())
            .padding(vertical = ChromeMetrics.railPadding, horizontal = ChromeMetrics.railPadding),
        verticalArrangement = Arrangement.spacedBy(ChromeMetrics.buttonGap),
    ) { content() }
}

/** How tall a rail may be, so it stops above the pointer controls instead of under them. */
fun Modifier.railMaxHeight(available: Dp): Modifier = if (available > 0.dp) height(available) else fillMaxHeight()
