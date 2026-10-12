package pl.dmq.peering.feature.remote

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import pl.dmq.peering.session.history.SessionRecord
import pl.dmq.peering.ui.theme.PeeringTheme

private val liveDirect = SessionOverlayState.of(
    hostName = "Damian's laptop",
    latencyMs = 24,
    path = SessionRecord.Path.DIRECT,
    picture = PictureState.LIVE,
    reconnecting = false,
    relayMinutesLeft = null,
)

private val allActions = ToolbarPresenter().actions(HubCapabilities(agentChat = true, fileBrowser = true))

@Composable
private fun PreviewFrame(content: @Composable () -> Unit) {
    PeeringTheme {
        Box(Modifier.background(Color.Black).padding(8.dp)) { content() }
    }
}

@Preview(name = "Top bar, direct", widthDp = 360)
@Composable
private fun TopBarDirectPreview() = PreviewFrame {
    SessionTopBar(liveDirect, zoomPercent = null, onFit = ::ignore, onDisconnect = ::ignore)
}

@Preview(name = "Top bar, relay, zoomed, long name", widthDp = 360)
@Composable
private fun TopBarRelayPreview() = PreviewFrame {
    SessionTopBar(
        liveDirect.copy(hostName = "A computer with a very long name indeed", path = SessionRecord.Path.RELAY),
        zoomPercent = 250,
        onFit = ::ignore,
        onDisconnect = ::ignore,
    )
}

@Preview(name = "Route pill", widthDp = 200)
@Composable
private fun RoutePillPreview() = PreviewFrame {
    Column { RoutePill(liveDirect) }
}

@Preview(name = "Action bar", widthDp = 360)
@Composable
private fun ActionBarPreview() = PreviewFrame {
    SessionActionBar(allActions, keyboardShown = true, vertical = false, onAction = ::ignore)
}

@Preview(name = "Action bar, landscape rail", heightDp = 360)
@Composable
private fun ActionBarRailPreview() = PreviewFrame {
    SessionActionBar(allActions, keyboardShown = false, vertical = true, onAction = ::ignore)
}

@Preview(name = "Keyboard panel", widthDp = 360)
@Composable
private fun KeyboardPanelPreview() = PreviewFrame {
    KeyboardPanel(
        latches = mapOf(StickyModifier.CONTROL to ModifierLatch.LATCHED, StickyModifier.SHIFT to ModifierLatch.LOCKED),
        onFunctionKey = ::ignore,
        onEditingKey = ::ignore,
        onModifier = ::ignore,
    )
}

@Preview(name = "Picture waiting", widthDp = 360)
@Composable
private fun PictureWaitingPreview() = PreviewFrame { PictureStatus(PictureState.WAITING, onRetry = ::ignore) }

@Preview(name = "Picture stalled", widthDp = 360)
@Composable
private fun PictureStalledPreview() = PreviewFrame { PictureStatus(PictureState.STALLED, onRetry = ::ignore) }

@Preview(name = "Picture failed", widthDp = 360)
@Composable
private fun PictureFailedPreview() = PreviewFrame { PictureStatus(PictureState.FAILED, onRetry = ::ignore) }

@Preview(name = "Reconnecting snackbar", widthDp = 360)
@Composable
private fun SnackbarPreview() = PreviewFrame { SessionSnackbar(liveDirect.copy(reconnecting = true)) }

private fun ignore() = Unit

@Suppress("UNUSED_PARAMETER")
private fun <T> ignore(value: T) = Unit
