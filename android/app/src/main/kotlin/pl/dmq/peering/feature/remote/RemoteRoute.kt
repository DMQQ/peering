package pl.dmq.peering.feature.remote

import android.os.SystemClock
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.ui.theme.peeringBackdrop

/** The remote screen for a connected Mac: the picture, the status line, the keyboard and the session menu. */
@Composable
fun RemoteRoute(model: RemoteModel) {
    val state by model.state.collectAsState()
    val canvas = remember(model) { RemoteCanvasPresenter(model.commands, state.inputMode) }
    val keyboard = remember(model) { KeyboardPresenter(model.commands) }
    val sources = remember(model) { SourcesPresenter(model.commands) }
    val hub = remember { HubPresenter() }
    val latches by keyboard.latches.collectAsState()
    var sourcesOpen by rememberSaveable { mutableStateOf(false) }
    var hubOpen by rememberSaveable { mutableStateOf(false) }
    var keyboardShown by rememberSaveable { mutableStateOf(false) }

    LaunchedEffect(state.inputMode) { canvas.setMode(state.inputMode) }
    LaunchedEffect(state.picturePixels) { canvas.onPictureChanged(state.picturePixels) }

    Box(modifier = Modifier.fillMaxSize().peeringBackdrop()) {
        RemoteCanvas(presenter = canvas, surface = model.surface, modifier = Modifier.fillMaxSize())

        SessionOverlay(
            state = SessionOverlayState.of(
                latencyMs = state.latencyMs,
                path = state.path,
                picture = state.pictureState,
                relayMinutesLeft = state.relayMinutesLeft,
            ),
            modifier = Modifier.statusBarsPadding().padding(horizontal = 16.dp, vertical = 8.dp),
        )

        Column(
            modifier = Modifier.align(Alignment.BottomCenter).navigationBarsPadding().padding(bottom = 8.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            if (keyboardShown) {
                FunctionKeyRow(onKey = keyboard::onFunctionKey)
                ModifierBar(
                    latches = latches,
                    onTap = { keyboard.onModifierTap(it, SystemClock.uptimeMillis()) },
                    modifier = Modifier.padding(horizontal = 16.dp),
                )
            }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.padding(horizontal = 16.dp)) {
                KeyCap(
                    label = stringResource(R.string.remote_keyboard),
                    selected = keyboardShown,
                    outlinedInAccent = false,
                    onClick = { keyboardShown = !keyboardShown },
                )
                KeyCap(
                    label = stringResource(R.string.remote_menu),
                    selected = false,
                    outlinedInAccent = false,
                    onClick = { hubOpen = true },
                )
            }
        }

        KeyboardBridge(presenter = keyboard, shown = keyboardShown)

        if (sourcesOpen) {
            SourcesSheet(
                catalog = state.catalog,
                chosen = state.chosenSource,
                presenter = sources,
                onDismiss = { sourcesOpen = false },
            )
        }
        if (hubOpen) {
            HubSheet(
                entries = hub.entries(state.capabilities),
                onSelect = { entry ->
                    hubOpen = false
                    if (entry == HubEntry.SOURCES) sourcesOpen = true else model.onHubEntry(entry)
                },
                onDismiss = { hubOpen = false },
            )
        }
    }
}
