package pl.dmq.peering.feature.terminal

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import pl.dmq.peering.R
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.kit.sessionSurface
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText
import pl.dmq.peering.ui.theme.PillShape

/**
 * The floating bar of the Terminals page: a white capsule that starts a shell, and a Files button beside it when the
 * computer can browse. Pressing either shrinks and fades it, as on the iPhone.
 */
@Composable
fun TerminalDock(onNew: () -> Unit, newEnabled: Boolean, onFiles: (() -> Unit)?, modifier: Modifier = Modifier) {
    Row(
        modifier.fillMaxWidth().navigationBarsPadding().padding(start = 16.dp, end = 16.dp, top = 8.dp, bottom = 6.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (onFiles != null) FilesButton(onFiles)
        NewTerminalButton(onNew, newEnabled, Modifier.weight(1f))
    }
}

@Composable
private fun FilesButton(onClick: () -> Unit) {
    Column(
        Modifier.width(58.dp).height(48.dp).railPress(onClick, scale = 0.97f).sessionSurface(PillShape),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(2.dp, Alignment.CenterVertically),
    ) {
        Icon(AppIcons.folder, contentDescription = stringResource(R.string.terminal_dock_files_description), tint = PeeringColors.ink, modifier = Modifier.size(18.dp))
        Text(stringResource(R.string.terminal_dock_files), fontSize = 10.sp, fontWeight = FontWeight.Medium, color = PeeringColors.ink, maxLines = 1)
    }
}

@Composable
private fun NewTerminalButton(onClick: () -> Unit, enabled: Boolean, modifier: Modifier) {
    val label = stringResource(R.string.terminal_new)
    Row(
        modifier
            .height(48.dp)
            .railPress(onClick, enabled = enabled, scale = 0.97f)
            .clip(PillShape)
            .background(PeeringColors.ink.copy(alpha = if (enabled) 1f else 0.4f))
            .padding(start = 8.dp, end = 14.dp),
        horizontalArrangement = Arrangement.spacedBy(10.dp, Alignment.CenterHorizontally),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(Modifier.size(32.dp).clip(PillShape).background(PeeringColors.onInk), contentAlignment = Alignment.Center) {
            Icon(TerminalGlyphs.add, contentDescription = null, tint = PeeringColors.ink, modifier = Modifier.size(16.dp))
        }
        Text(label, style = PeeringText.subheadlineSemibold.copy(fontSize = 15.5.sp), color = PeeringColors.onInk, maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}
