package pl.dmq.peering.feature.files

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.NorthWest
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.kit.englishDate
import pl.dmq.peering.ui.theme.FileTileShape
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText

/**
 * One entry of a folder, laid out as the iPhone's file row: a 28 point rounded tile, the name in subheadline medium, the
 * mode and size and date under it, and a chevron. A tap opens it, or toggles it while a selection is going; a long press
 * starts one.
 */
@Composable
fun FileEntryRow(row: FileRowUi, onClick: () -> Unit, onLongClick: () -> Unit, modifier: Modifier = Modifier) {
    val detail = remember(row.entry, row.modifiedEpochMillis) {
        FileRowDetail.of(row.entry, row.modifiedEpochMillis?.let(::englishDate))
    }
    FileRowFrame(
        icon = if (row.isSelected) AppIcons.check else row.glyph.icon,
        title = row.name,
        detail = detail,
        isSelected = row.isSelected,
        onClick = onClick,
        onLongClick = onLongClick,
        modifier = modifier,
    )
}

/** The row that climbs one level, drawn like the iPhone's ".." entry. */
@Composable
fun UpRow(onClick: () -> Unit, modifier: Modifier = Modifier) {
    FileRowFrame(
        icon = Icons.Outlined.NorthWest,
        title = "..",
        detail = null,
        subtitle = "Up one level",
        monospacedTitle = true,
        showsChevron = false,
        onClick = onClick,
        onLongClick = null,
        modifier = modifier,
    )
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun FileRowFrame(
    icon: ImageVector,
    title: String,
    detail: FileRowDetail?,
    onClick: () -> Unit,
    onLongClick: (() -> Unit)?,
    modifier: Modifier = Modifier,
    subtitle: String? = null,
    isSelected: Boolean = false,
    monospacedTitle: Boolean = false,
    showsChevron: Boolean = true,
) {
    val source = remember { MutableInteractionSource() }
    val pressed by source.collectIsPressedAsState()
    val dim = animateFloatAsState(if (pressed) 1f else 0f, tween(PRESS_MILLIS), label = "rowPress")
    Row(
        modifier = modifier
            .fillMaxWidth()
            .background(if (isSelected) PeeringColors.selectedIndicator.copy(alpha = 0.5f) else Color.Transparent)
            .combinedClickable(interactionSource = source, indication = null, role = Role.Button, onClick = onClick, onLongClick = onLongClick)
            .graphicsLayer { alpha = 1f - (1f - PRESSED_ALPHA) * dim.value }
            .padding(horizontal = 16.dp, vertical = 8.dp),
        horizontalArrangement = Arrangement.spacedBy(11.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Tile(icon, isSelected)
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(
                title,
                style = PeeringText.subheadlineMedium.let { if (monospacedTitle) it.copy(fontFamily = FontFamily.Monospace) else it },
                color = PeeringColors.ink,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            if (detail != null) {
                Text(detailText(detail), style = PeeringText.caption, color = PeeringColors.muted, maxLines = 1, overflow = TextOverflow.Ellipsis)
            } else if (subtitle != null) {
                Text(subtitle, style = PeeringText.caption, color = PeeringColors.muted, maxLines = 1)
            }
        }
        if (showsChevron) {
            Icon(AppIcons.chevronRight, contentDescription = null, tint = PeeringColors.tertiary, modifier = Modifier.size(16.dp))
        }
    }
}

@Composable
private fun Tile(icon: ImageVector, isSelected: Boolean) {
    val tint = if (isSelected) PeeringColors.accent else PeeringColors.ink
    Box(
        modifier = Modifier.size(28.dp).background(tint.copy(alpha = TILE_ALPHA), FileTileShape),
        contentAlignment = Alignment.Center,
    ) {
        Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(15.dp))
    }
}

private fun detailText(detail: FileRowDetail) = buildAnnotatedString {
    if (detail.mode.isNotEmpty()) {
        withStyle(SpanStyle(fontFamily = FontFamily.Monospace, fontSize = 11.sp)) { append(detail.mode) }
    }
    append(detail.rest)
}

private const val TILE_ALPHA = 0.14f
private const val PRESS_MILLIS = 120
private const val PRESSED_ALPHA = 0.6f
