package pl.dmq.peering.feature.remote

import androidx.compose.runtime.Composable
import androidx.compose.ui.res.stringResource
import pl.dmq.peering.R
import pl.dmq.peering.ui.kit.PeeringAlert
import pl.dmq.peering.wire.Modifiers

/** The questions the session screen asks before it does something it cannot take back, and the macro editor. */
@Composable
internal fun RemoteDialogs(
    model: RemoteModel,
    screen: SessionScreenState,
    actions: RemoteActions,
    customMacros: List<Macro>,
    hostName: String?,
) {
    if (screen.leaveAsked) {
        PeeringAlert(
            title = stringResource(R.string.remote_leave_title),
            message = stringResource(R.string.remote_leave_message, hostName ?: stringResource(R.string.remote_computer_fallback)),
            confirm = stringResource(R.string.remote_leave_confirm),
            onConfirm = {
                screen.leaveAsked = false
                model.onHubEntry(HubEntry.DISCONNECT)
            },
            cancel = stringResource(R.string.remote_leave_cancel),
            onCancel = { screen.leaveAsked = false },
            destructive = true,
        )
    }
    if (screen.quitAsked) {
        PeeringAlert(
            title = stringResource(R.string.remote_quit_title),
            message = stringResource(R.string.remote_quit_message),
            confirm = stringResource(R.string.remote_quit_confirm),
            onConfirm = {
                screen.quitAsked = false
                actions.sendKey(QUIT_KEY, Modifiers.COMMAND)
            },
            cancel = stringResource(R.string.remote_leave_cancel),
            onCancel = { screen.quitAsked = false },
            destructive = true,
        )
    }
    if (screen.macrosOpen) {
        MacroEditorSheet(
            custom = customMacros,
            onAdd = { macro -> model.macros.add(macro) },
            onRemove = { id -> model.macros.remove(id) },
            onDismiss = { screen.macrosOpen = false },
        )
    }
}

private const val QUIT_KEY = 12
