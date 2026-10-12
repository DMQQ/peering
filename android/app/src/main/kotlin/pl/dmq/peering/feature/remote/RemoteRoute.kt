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
import pl.dmq.peering.R
import pl.dmq.peering.ui.kit.PeeringAlert

/** The remote screen for a connected computer: the picture, the top bar, the action bar, the keyboard and the More sheet. */
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
    var immersive by rememberSaveable { mutableStateOf(false) }
    var lastHostName by rememberSaveable { mutableStateOf<String?>(null) }
    state.hostName?.let { lastHostName = it }

    val chromeShown = ChromePolicy.shown(immersive, state.pictureState, state.reconnecting)
    val zoomPercent = (canvasState.viewport.zoom * 100).roundToInt().takeIf { it > ZOOMED_PERCENT }

    LaunchedEffect(mode) { canvas.setMode(mode) }
    LaunchedEffect(state.picturePixels) { canvas.onPictureChanged(state.picturePixels) }

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
                modifier = Modifier.fillMaxSize().displayCutoutPadding(),
            )
            RemoteChrome(
                shown = chromeShown,
                overlay = SessionOverlayState.of(
                    hostName = lastHostName,
                    latencyMs = state.latencyMs,
                    path = state.path,
                    picture = state.pictureState,
                    reconnecting = state.reconnecting,
                    relayMinutesLeft = state.relayMinutesLeft,
                ),
                zoomPercent = zoomPercent,
                actions = toolbar.actions(state.capabilities),
                keyboardShown = keyboardShown,
                latches = latches,
                immersive = immersive,
                onReveal = { immersive = false },
                onFit = canvas::fitToCanvas,
                onRetry = model::onRetryPicture,
                onDisconnect = { leaveAsked = true },
                onAction = { action ->
                    when (val effect = toolbar.effect(action)) {
                        ToolbarEffect.ToggleKeyboard -> keyboardShown = !keyboardShown
                        ToolbarEffect.OpenSources -> sourcesOpen = true
                        ToolbarEffect.OpenMore -> hubOpen = true
                        is ToolbarEffect.OpenHub -> model.onHubEntry(effect.entry)
                    }
                },
                onFunctionKey = keyboard::onFunctionKey,
                onEditingKey = keyboard::onEditingKey,
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
                entries = hub.moreEntries(),
                mode = mode,
                immersive = immersive,
                onToggleImmersive = { immersive = !immersive },
                onToggleMode = {
                    haptics.performHapticFeedback(HapticFeedbackType.LongPress)
                    mode = toolbar.otherMode(mode)
                },
                onSelect = { entry ->
                    hubOpen = false
                    when (entry) {
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
