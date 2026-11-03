package pl.dmq.peering.feature.sessionmode

import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.Undo
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.ContentCopy
import androidx.compose.material.icons.outlined.ContentPaste
import androidx.compose.material.icons.outlined.Dashboard
import androidx.compose.material.icons.outlined.FilterNone
import androidx.compose.material.icons.outlined.PowerSettingsNew
import androidx.compose.material.icons.outlined.Screenshot
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material.icons.outlined.Wallpaper
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.ui.kit.CardShape
import pl.dmq.peering.ui.kit.PeeringSheet
import pl.dmq.peering.ui.kit.tappable
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText

/**
 * A grid of [DockShortcut]s; a tap sends the chord to the computer and closes the sheet. Rows, not a lazy grid, so the
 * sheet measures every card and opens tall enough to show all of them.
 */
@Composable
fun RemoteDockShortcutsSheet(onShortcut: (DockShortcut) -> Unit, onDismiss: () -> Unit) {
    PeeringSheet(onDismiss, scrollable = true) {
        BoxWithConstraints(Modifier.fillMaxWidth().padding(horizontal = 18.dp)) {
            val columns = ((maxWidth + GAP) / (MIN_CARD_WIDTH + GAP)).toInt().coerceAtLeast(1)
            Column(verticalArrangement = Arrangement.spacedBy(GAP)) {
                SheetHeader(stringResource(R.string.remote_dock_shortcuts), null)
                DockShortcut.entries.chunked(columns).forEach { row -> ShortcutRow(row, columns, onShortcut, onDismiss) }
            }
        }
    }
}

@Composable
private fun ShortcutRow(row: List<DockShortcut>, columns: Int, onShortcut: (DockShortcut) -> Unit, onDismiss: () -> Unit) {
    Row(horizontalArrangement = Arrangement.spacedBy(GAP)) {
        row.forEach { shortcut ->
            Box(Modifier.weight(1f)) {
                ShortcutCard(shortcut) {
                    onShortcut(shortcut)
                    onDismiss()
                }
            }
        }
        repeat(columns - row.size) { Spacer(Modifier.weight(1f)) }
    }
}

private val GAP = 12.dp
private val MIN_CARD_WIDTH = 96.dp

@Composable
private fun ShortcutCard(shortcut: DockShortcut, onClick: () -> Unit) {
    Column(
        Modifier
            .fillMaxWidth()
            .heightIn(min = 84.dp)
            .clip(CardShape)
            .border(1.dp, PeeringColors.outline, CardShape)
            .tappable(onClick)
            .padding(8.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterVertically),
    ) {
        Icon(shortcut.icon(), contentDescription = null, tint = PeeringColors.ink, modifier = Modifier.size(22.dp))
        Text(stringResource(shortcut.titleRes()), style = PeeringText.footnote, color = PeeringColors.ink, maxLines = 2, textAlign = TextAlign.Center)
    }
}

/** The sheets' heading in the tabs' title face, with an optional line under it. */
@Composable
internal fun SheetHeader(title: String, detail: String?) {
    Column(Modifier.fillMaxWidth().padding(bottom = 8.dp), verticalArrangement = Arrangement.spacedBy(5.dp)) {
        Text(title, style = PeeringText.display(size = 28f, tracking = -0.8f), color = PeeringColors.ink)
        if (detail != null) Text(detail, style = PeeringText.subheadline, color = PeeringColors.muted)
    }
}

private fun DockShortcut.icon(): ImageVector = when (this) {
    DockShortcut.SPOTLIGHT -> Icons.Outlined.Search
    DockShortcut.SWITCH_APP -> Icons.Outlined.FilterNone
    DockShortcut.MISSION_CONTROL -> Icons.Outlined.Dashboard
    DockShortcut.SHOW_DESKTOP -> Icons.Outlined.Wallpaper
    DockShortcut.COPY -> Icons.Outlined.ContentCopy
    DockShortcut.PASTE -> Icons.Outlined.ContentPaste
    DockShortcut.UNDO -> Icons.AutoMirrored.Outlined.Undo
    DockShortcut.CLOSE_WINDOW -> Icons.Outlined.Close
    DockShortcut.QUIT_APP -> Icons.Outlined.PowerSettingsNew
    DockShortcut.SCREENSHOT -> Icons.Outlined.Screenshot
}

private fun DockShortcut.titleRes(): Int = when (this) {
    DockShortcut.SPOTLIGHT -> R.string.dock_shortcut_spotlight
    DockShortcut.SWITCH_APP -> R.string.dock_shortcut_switch_app
    DockShortcut.MISSION_CONTROL -> R.string.dock_shortcut_mission_control
    DockShortcut.SHOW_DESKTOP -> R.string.dock_shortcut_show_desktop
    DockShortcut.COPY -> R.string.dock_shortcut_copy
    DockShortcut.PASTE -> R.string.dock_shortcut_paste
    DockShortcut.UNDO -> R.string.dock_shortcut_undo
    DockShortcut.CLOSE_WINDOW -> R.string.dock_shortcut_close_window
    DockShortcut.QUIT_APP -> R.string.dock_shortcut_quit_app
    DockShortcut.SCREENSHOT -> R.string.dock_shortcut_screenshot
}
