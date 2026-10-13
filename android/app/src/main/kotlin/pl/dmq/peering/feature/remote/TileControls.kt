package pl.dmq.peering.feature.remote

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Remove
import androidx.compose.material3.Icon
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.delay
import pl.dmq.peering.R
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.kit.pressable

/** One round button on a tile after a long press. */
class TileControl(val action: TileAction, val onClick: () -> Unit)

private val Red = Color(0xFFFF5F57)
private val Yellow = Color(0xFFFFBD2E)
private val Green = Color(0xFF29C940)
private const val HIDE_AFTER_MILLIS = 4_000L

/** The one place the panel uses colours other than the state blue: they quote the Mac's title bar buttons. */
@Composable
internal fun TileControlBar(controls: List<TileControl>, onDone: () -> Unit, modifier: Modifier = Modifier) {
    LaunchedEffect(controls.size) {
        delay(HIDE_AFTER_MILLIS)
        onDone()
    }
    Row(
        modifier.background(Color.Black.copy(alpha = 0.55f), CircleShape).padding(5.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        controls.forEach { control ->
            val label = stringResource(control.action.label)
            Box(
                Modifier.size(24.dp).background(control.action.colour, CircleShape)
                    .pressable({
                        control.onClick()
                        onDone()
                    })
                    .semantics { contentDescription = label },
                contentAlignment = Alignment.Center,
            ) {
                Icon(control.action.icon, contentDescription = null, tint = Color.Black.copy(alpha = 0.6f), modifier = Modifier.size(13.dp))
            }
        }
    }
}

private val TileAction.colour: Color get() = when (this) {
    TileAction.CLOSE, TileAction.REMOVE -> Red
    TileAction.MINIMISE, TileAction.RENAME -> Yellow
    TileAction.ZOOM -> Green
}

private val TileAction.icon: ImageVector get() = when (this) {
    TileAction.CLOSE, TileAction.REMOVE -> AppIcons.close
    TileAction.MINIMISE -> Icons.Outlined.Remove
    TileAction.ZOOM -> AppIcons.fit
    TileAction.RENAME -> AppIcons.edit
}

private val TileAction.label: Int get() = when (this) {
    TileAction.CLOSE -> R.string.sources_action_close
    TileAction.MINIMISE -> R.string.sources_action_minimise
    TileAction.ZOOM -> R.string.sources_action_zoom
    TileAction.REMOVE -> R.string.sources_action_remove_display
    TileAction.RENAME -> R.string.sources_action_rename_display
}
