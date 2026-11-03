package pl.dmq.peering.feature.sessionmode

import android.os.SystemClock
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.feature.remote.InputMode
import pl.dmq.peering.feature.remote.KeyboardPresenter
import pl.dmq.peering.feature.remote.PointerTracker
import pl.dmq.peering.feature.remote.RemoteCanvasPresenter
import pl.dmq.peering.feature.remote.RemoteModel
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.kit.sessionSurface
import pl.dmq.peering.ui.kit.tappable
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText
import pl.dmq.peering.ui.theme.PillShape
import pl.dmq.peering.ui.theme.peeringBackdrop
import pl.dmq.peering.wire.LaunchApplication
import pl.dmq.peering.wire.LockScreen
import pl.dmq.peering.wire.RefreshSpacePreviews
import pl.dmq.peering.wire.SwitchToSpace
import pl.dmq.peering.wire.spaces

/**
 * Controls the computer with no picture: a trackpad that moves, clicks, scrolls and swipes between desktops, a keyboard,
 * the computer's apps and shortcuts, and lock. The finger moves the computer's real pointer from where it last said it was.
 */
@Composable
fun RemoteDock(model: RemoteModel, favourites: ApplicationFavourites?, onShowScreen: () -> Unit, onChangeMode: () -> Unit, modifier: Modifier = Modifier) {
    val state by model.state.collectAsState()
    val tracker = remember(model) { PointerTracker(model.commands) { 1.0 to 1.0 } }
    val pad = remember(tracker) { RemoteCanvasPresenter(tracker, InputMode.TRACKPAD) { tracker.position.value } }
    val keyboard = remember(tracker) { KeyboardPresenter(tracker) }
    val display = state.catalog?.spaces?.displays?.firstOrNull()
    val currentDisplay by rememberUpdatedState(display)
    val buttons = RemoteDockButtons(desktops = state.sourcesFeatures.desktops, apps = state.sourcesFeatures.windowControls, lock = state.screenControls)
    val currentButtons by rememberUpdatedState(buttons)
    val density = LocalDensity.current
    val gestures = remember(pad) {
        TrackpadGestures(pad, with(density) { 40.dp.toPx().toDouble() }, with(density) { 10.dp.toPx().toDouble() }) { swipe ->
            swipe.commands(currentDisplay, currentButtons.desktops).forEach(model.commands::send)
        }
    }
    var typing by rememberSaveable { mutableStateOf(false) }
    var fillsScreen by rememberSaveable { mutableStateOf(false) }
    var sheet by rememberSaveable { mutableStateOf(DockSheet.NONE) }
    LaunchedEffect(state.hostPointer) {
        val reported = state.hostPointer ?: return@LaunchedEffect
        if (gestures.adoptsHostPointer(SystemClock.uptimeMillis())) tracker.report(reported.point)
    }

    Column(
        modifier.fillMaxSize().peeringBackdrop().windowInsetsPadding(WindowInsets.safeDrawing).padding(horizontal = 16.dp, vertical = 10.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        if (!fillsScreen) DockHeader(state.hostName, onShowScreen, onChangeMode)
        RemoteDockPad(pad, gestures, fillsScreen, { fillsScreen = !fillsScreen }, Modifier.weight(1f).fillMaxWidth())
        if (!fillsScreen) {
            if (typing) RemoteDockTypingField(keyboard, onDone = { typing = false })
            RemoteDockBar(
                typing,
                display,
                buttons,
                RemoteDockBarActions(
                    onKeyboard = { typing = true },
                    onDesktops = { sheet = DockSheet.DESKTOPS },
                    onApps = { sheet = DockSheet.APPS },
                    onShortcuts = { sheet = DockSheet.SHORTCUTS },
                    onLock = { model.commands.send(LockScreen) },
                    onKey = { code -> keyboard.sendKey(code) },
                ),
            )
        }
    }
    when (sheet) {
        DockSheet.APPS -> RemoteDockAppsSheet(state.catalog, favourites, { model.commands.send(LaunchApplication(it)) }, { sheet = DockSheet.NONE })
        DockSheet.SHORTCUTS -> RemoteDockShortcutsSheet({ keyboard.sendKey(it.keyCode, it.modifiers) }, { sheet = DockSheet.NONE })
        DockSheet.DESKTOPS -> RemoteDockDesktopsSheet(
            state.catalog,
            onOpen = { model.commands.send(RefreshSpacePreviews) },
            onSwitch = { desktop, index -> model.commands.send(SwitchToSpace(desktop.displayId, index)) },
            onDismiss = { sheet = DockSheet.NONE },
        )
        DockSheet.NONE -> Unit
    }
}

private enum class DockSheet { NONE, APPS, SHORTCUTS, DESKTOPS }

@Composable
private fun DockHeader(hostName: String?, onShowScreen: () -> Unit, onChangeMode: () -> Unit) {
    Row(Modifier.fillMaxWidth().padding(top = 8.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        Text(
            hostName.orEmpty(),
            style = PeeringText.display(size = 34f, tracking = -1.2f),
            color = PeeringColors.ink,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f),
        )
        Row(Modifier.sessionSurface(PillShape).padding(horizontal = 4.dp)) {
            HeaderButton(AppIcons.display, stringResource(R.string.dock_show_screen), onShowScreen)
            HeaderButton(AppIcons.grid, stringResource(R.string.dock_change_mode), onChangeMode)
        }
    }
}

@Composable
private fun HeaderButton(icon: ImageVector, label: String, onClick: () -> Unit) {
    Box(Modifier.size(44.dp).tappable(onClick).semantics { contentDescription = label }, contentAlignment = Alignment.Center) {
        Icon(icon, contentDescription = null, tint = PeeringColors.ink, modifier = Modifier.size(20.dp))
    }
}
