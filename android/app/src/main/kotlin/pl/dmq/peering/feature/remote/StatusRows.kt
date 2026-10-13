package pl.dmq.peering.feature.remote

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.runtime.Composable
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.kit.SessionIcons

/** The expanded pill's rows, in the phone's order: View, Computer, Session, End. The Stream row has no source here. */
@Composable
internal fun StatusRows(ui: StatusUi, actions: StatusActions) {
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        PillRow(stringResource(R.string.remote_row_view), AppIcons.fit, viewChips(ui, actions))
        PillRow(
            stringResource(R.string.remote_row_computer),
            AppIcons.computer,
            listOf(
                PillChipSpec(stringResource(R.string.remote_chip_lock), AppIcons.encrypted, actions.onLock),
                PillChipSpec(
                    stringResource(if (ui.darkened) R.string.remote_chip_restore else R.string.remote_chip_darken),
                    if (ui.darkened) SessionIcons.bright else SessionIcons.dim,
                    actions.onToggleDark,
                ),
                PillChipSpec(stringResource(R.string.remote_chip_screenshot), AppIcons.camera, actions.onScreenshot),
            ),
        )
        PillRow(
            stringResource(R.string.remote_row_session),
            AppIcons.reconnect,
            buildList {
                add(PillChipSpec(stringResource(R.string.remote_chip_connect), AppIcons.devices, actions.onStepAway))
                terminalChip(ui, actions)?.let(::add)
            },
        )
        PillRow(
            stringResource(R.string.remote_row_end),
            AppIcons.power,
            listOf(PillChipSpec(stringResource(R.string.remote_chip_quit), null, actions.onQuit, destructive = true)),
        )
    }
}

@Composable
private fun viewChips(ui: StatusUi, actions: StatusActions): List<PillChipSpec> = buildList {
    add(
        PillChipSpec(
            stringResource(if (ui.fills) R.string.remote_chip_fit else R.string.remote_chip_fill),
            if (ui.fills) AppIcons.fit else SessionIcons.fill,
            actions.onToggleFill,
        ),
    )
    ui.zoomPercent?.let { add(PillChipSpec(stringResource(R.string.remote_zoom_percent, it), null, actions.onResetZoom)) }
    add(PillChipSpec(stringResource(R.string.remote_chip_immersive), SessionIcons.immersive, actions.onImmersive))
}

/** The Terminal chip opens the hub panel. */
@Composable
private fun terminalChip(ui: StatusUi, actions: StatusActions): PillChipSpec? {
    if (ui.hubTabs.isEmpty()) return null
    return PillChipSpec(stringResource(R.string.remote_chip_terminal), SessionIcons.terminal, onClick = actions.onOpenHub)
}
