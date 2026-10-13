package pl.dmq.peering.feature.terminal

import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import pl.dmq.peering.R
import pl.dmq.peering.session.terminal.TerminalTab
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.theme.PeeringColors

/** Back, the terminal's name (a long press renames it), and a cross that ends it, on the terminal's own backdrop. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TerminalTopBar(tab: TerminalTab?, onBack: () -> Unit, onRename: (TerminalTab) -> Unit, onEnd: (TerminalTab) -> Unit) {
    TopAppBar(
        title = {
            Text(
                tab?.name ?: stringResource(R.string.terminal_title),
                modifier = if (tab != null) Modifier.pointerInput(tab.id) { detectTapGestures(onLongPress = { onRename(tab) }) } else Modifier,
                fontWeight = FontWeight.SemiBold,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        },
        navigationIcon = { IconButton(onClick = onBack) { Icon(AppIcons.back, stringResource(R.string.terminal_back)) } },
        actions = {
            if (tab != null) {
                IconButton(onClick = { onEnd(tab) }) { Icon(AppIcons.close, stringResource(R.string.terminal_end_named, tab.name)) }
            }
        },
        colors = TopAppBarDefaults.topAppBarColors(
            containerColor = PeeringColors.backdrop,
            titleContentColor = PeeringColors.ink,
            navigationIconContentColor = PeeringColors.ink,
            actionIconContentColor = PeeringColors.ink,
        ),
    )
}
