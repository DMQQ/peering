package pl.dmq.peering.feature.remote

import android.os.SystemClock
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.displayCutoutPadding
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.imePadding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.res.stringResource
import kotlin.math.roundToInt
import kotlinx.coroutines.delay
import pl.dmq.peering.R
import pl.dmq.peering.ui.kit.PeeringAlert

/** The remote screen for a connected computer: the picture, the status pill, the toolbar, the keyboard and the session menu. */
@Composable
fun RemoteRoute(model: RemoteModel) {
    val state by model.state.collectAsState()
    val canvas = remember(model) { RemoteCanvasPresenter(model.commands, state.inputMode) }
    val keyboard = remember(model) { KeyboardPresenter(model.commands) }
    val sources = remember(model) { SourcesPresenter(model.commands) }
    val hub = remember { HubPresenter() }
    val toolbar = remember { ToolbarPresenter() }
    val scope = rememberCoroutineScope()
    val qualitySheet = remember(model) {
        QualitySheetPresenter(model.quality, scope, onNeedsUpgrade = model::onRelayUpgradeRequested)
    }
    val haptics = LocalHapticFeedback.current
    val latches by keyboard.latches.collectAsState()
    val canvasState by canvas.state.collectAsState()
    var mode by rememberSaveable { mutableStateOf(state.inputMode) }
    var sourcesOpen by rememberSaveable { mutableStateOf(false) }
    var hubOpen by rememberSaveable { mutableStateOf(false) }
    var qualityOpen by rememberSaveable { mutableStateOf(false) }
    var leaveAsked by rememberSaveable { mutableStateOf(false) }
    var keyboardShown by rememberSaveable { mutableStateOf(false) }
    var chromeShown by rememberSaveable { mutableStateOf(true) }
    var touches by remember { mutableIntStateOf(0) }
    var lastHostName by rememberSaveable { mutableStateOf<String?>(null) }
    state.hostName?.let { lastHostName = it }

    val overlayOpen = sourcesOpen || hubOpen || qualityOpen || leaveAsked
    val holdsChrome = ChromePolicy.holdsChrome(keyboardShown, overlayOpen, state.pictureState, state.reconnecting)
    val zoomPercent = (canvasState.viewport.zoom * 100).roundToInt().takeIf { it > ZOOMED_PERCENT }

    LaunchedEffect(mode) { canvas.setMode(mode) }
    LaunchedEffect(state.picturePixels) { canvas.onPictureChanged(state.picturePixels) }
    LaunchedEffect(chromeShown, holdsChrome, touches) {
        if (chromeShown && !holdsChrome) {
            delay(ChromePolicy.AUTO_HIDE_MS)
            chromeShown = false
        }
    }

    SessionWindow()
    BackHandler {
        when (BackStep.of(keyboardShown)) {
            BackStep.HIDE_KEYBOARD -> keyboardShown = false
            BackStep.ASK_TO_LEAVE -> leaveAsked = true
        }
    }

    Box(modifier = Modifier.fillMaxSize().background(Color.Black)) {
        Box(modifier = Modifier.fillMaxSize().imePadding()) {
            RemoteCanvas(
                presenter = canvas,
                surface = model.surface,
                onTouch = { touches++ },
                modifier = Modifier.fillMaxSize().displayCutoutPadding(),
            )
            RemoteChrome(
                shown = chromeShown || holdsChrome,
                overlay = SessionOverlayState.of(
                    hostName = lastHostName,
                    latencyMs = state.latencyMs,
                    path = state.path,
                    picture = state.pictureState,
                    reconnecting = state.reconnecting,
                    relayMinutesLeft = state.relayMinutesLeft,
                ),
                zoomPercent = zoomPercent,
                toolbar = toolbar.actions(zoomed = zoomPercent != null),
                keyboardShown = keyboardShown,
                mode = mode,
                latches = latches,
                onReveal = { chromeShown = true },
                onFit = canvas::fitToCanvas,
                onRetry = model::onRetryPicture,
                onDisconnect = { leaveAsked = true },
                onToolbar = { action ->
                    when (action) {
                        ToolbarAction.KEYBOARD -> keyboardShown = !keyboardShown
                        ToolbarAction.POINTER_MODE -> {
                            haptics.performHapticFeedback(HapticFeedbackType.LongPress)
                            mode = toolbar.otherMode(mode)
                        }
                        ToolbarAction.FIT -> canvas.fitToCanvas()
                        ToolbarAction.SOURCES -> sourcesOpen = true
                        ToolbarAction.QUALITY -> qualityOpen = true
                        ToolbarAction.MENU -> hubOpen = true
                    }
                },
                onFunctionKey = keyboard::onFunctionKey,
                onModifier = {
                    haptics.performHapticFeedback(HapticFeedbackType.TextHandleMove)
                    keyboard.onModifierTap(it, SystemClock.uptimeMillis())
                },
            )
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
        if (qualityOpen) {
            QualitySheet(presenter = qualitySheet, onDismiss = { qualityOpen = false })
        }
        if (hubOpen) {
            HubSheet(
                entries = hub.entries(state.capabilities),
                onSelect = { entry ->
                    hubOpen = false
                    when (entry) {
                        HubEntry.SOURCES -> sourcesOpen = true
                        HubEntry.QUALITY -> qualityOpen = true
                        HubEntry.DISCONNECT -> leaveAsked = true
                        else -> model.onHubEntry(entry)
                    }
                },
                onDismiss = { hubOpen = false },
            )
        }
        if (leaveAsked) {
            PeeringAlert(
                title = stringResource(R.string.remote_leave_title),
                message = stringResource(
                    R.string.remote_leave_message,
                    lastHostName ?: stringResource(R.string.remote_computer_fallback),
                ),
                confirm = stringResource(R.string.remote_leave_confirm),
                onConfirm = {
                    leaveAsked = false
                    model.onHubEntry(HubEntry.DISCONNECT)
                },
                cancel = stringResource(R.string.remote_leave_cancel),
                onCancel = { leaveAsked = false },
                destructive = true,
            )
        }
    }
}

private const val ZOOMED_PERCENT = 101
