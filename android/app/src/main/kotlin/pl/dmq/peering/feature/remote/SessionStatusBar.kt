package pl.dmq.peering.feature.remote

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.layout.layout
import androidx.compose.runtime.State
import androidx.compose.animation.core.tween
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.kit.PeeringMenu
import pl.dmq.peering.ui.kit.PeeringMenuItem
import pl.dmq.peering.ui.kit.SessionIcons
import pl.dmq.peering.ui.theme.PeeringColors

/**
 * The bar across the top of the picture: the lock button, the status pill, and the button to the terminal, agents and
 * files. Closed, the pill leaves room for both buttons; open, it takes the whole width.
 */
@Composable
fun SessionStatusBar(
    ui: StatusUi,
    actions: StatusActions,
    expanded: Boolean,
    onTap: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Box(modifier.fillMaxWidth().padding(horizontal = 6.dp)) {
        Box(Modifier.align(Alignment.TopStart)) { LockButton(ui, actions) }
        Box(Modifier.align(Alignment.TopEnd)) { TerminalButton(ui.hubTabs.isNotEmpty(), actions.onOpenHub) }
        StatusPill(ui, actions, expanded, onTap, Modifier.align(Alignment.TopStart).fillMaxWidth())
    }
}


@Composable
private fun LockButton(ui: StatusUi, actions: StatusActions) {
    var open by remember { mutableStateOf(false) }
    Box {
        CircleGlassButton(
            icon = AppIcons.encrypted,
            label = stringResource(R.string.remote_lock_description),
            onClick = actions.onLock,
            tint = if (ui.darkened) PeeringColors.accent else PeeringColors.ink,
            onLongClick = { open = true },
        )
        PeeringMenu(expanded = open, onDismiss = { open = false }) {
            PeeringMenuItem(
                title = stringResource(R.string.remote_menu_lock),
                icon = AppIcons.encrypted,
                onClick = {
                    open = false
                    actions.onLock()
                },
            )
            PeeringMenuItem(
                title = stringResource(if (ui.darkened) R.string.remote_menu_restore else R.string.remote_menu_dim),
                icon = if (ui.darkened) SessionIcons.bright else SessionIcons.dim,
                onClick = {
                    open = false
                    actions.onToggleDark()
                },
            )
        }
    }
}

@Composable
private fun TerminalButton(offered: Boolean, onOpen: () -> Unit) {
    Box(Modifier.alpha(if (offered) 1f else 0.45f)) {
        CircleGlassButton(
            icon = SessionIcons.terminal,
            label = stringResource(R.string.remote_terminal_description),
            onClick = { if (offered) onOpen() },
        )
    }
}
