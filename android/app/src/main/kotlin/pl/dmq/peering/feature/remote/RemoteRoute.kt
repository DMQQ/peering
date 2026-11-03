package pl.dmq.peering.feature.remote

import android.content.res.Configuration
import android.widget.Toast
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.displayCutoutPadding
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.imePadding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import pl.dmq.peering.R
import pl.dmq.peering.feature.files.FileShare
import pl.dmq.peering.feature.files.ShareRequest
import pl.dmq.peering.ui.wiring.findActivity
import pl.dmq.peering.feature.remote.dictation.rememberVoiceDictation
import pl.dmq.peering.feature.settings.DevicePrefs
import pl.dmq.peering.testing.RemoteBridge
import pl.dmq.peering.feature.sessionmode.commands
import pl.dmq.peering.ui.kit.LocalBorderless
import pl.dmq.peering.wire.ReportDeviceOrientation
import pl.dmq.peering.wire.SetCaptureSource
import pl.dmq.peering.wire.spaces

/** The remote screen for a connected computer: the picture, the chrome over it, the panels, and the keyboard. */
@Composable
fun RemoteRoute(model: RemoteModel) {
    val state by model.state.collectAsState()
    val prefs by model.prefs.prefs.collectAsState()
    val customMacros by model.macros.custom.collectAsState()
    val screen = rememberSaveable(saver = SessionScreenState.Saver) { SessionScreenState() }
    val scope = rememberCoroutineScope()
    val presenters = rememberSessionPresenters(model, state, prefs, screen, scope)
    val canvas = presenters.canvas
    val keyboard = presenters.keyboard
    val actions = presenters.actions
    canvas.onTileTapped = { source -> model.commands.send(SetCaptureSource(source)) }
    val spaceDisplay = state.catalog?.spaces?.displays?.firstOrNull()
    canvas.onSwiped = { swipe -> swipe.commands(spaceDisplay, state.sourcesFeatures.desktops).forEach(model.commands::send) }
    val canvasState by canvas.state.collectAsState()
    val cursor by presenters.tracker.position.collectAsState()
    val typed by keyboard.typedPreview.collectAsState()
    val latches by keyboard.latches.collectAsState()
    var lastHostName by rememberSaveable { mutableStateOf<String?>(null) }
    state.hostName?.let { lastHostName = it }
    val overlay = sessionOverlay(state, lastHostName)
    SessionEffects(state, prefs, screen, canvas, presenters.tracker, presenters.keyboard, presenters.follower)
    ReportOrientation(model, ready = state.hostName != null)
    val pill = rememberStatusPill(model, scope, ready = state.hostName != null)
    SessionWindow()
    RemoteBridge(screen, pill, actions, model.clipboard)
    RemoteBackHandler(screen)
    val pictureView = remember { PictureViewHolder() }
    val handlers = chromeHandlers(model, screen, pill, actions, canvas, keyboard, typed, latches, presenters.follower, rememberVoiceDictation(), shareScreenshot(pictureView, scope))
    val chrome = chromeState(state, prefs, screen, overlay, pill, canvasState.viewport.zoom)
    val panelContext = PanelContext(model, state, prefs, screen, actions, keyboard, presenters.sources, presenters.quality, customMacros, overlay)

    CompositionLocalProvider(LocalBorderless provides true) {
        Box(modifier = Modifier.fillMaxSize().background(Color.Black)) {
            Box(modifier = Modifier.fillMaxSize().imePadding()) {
                RemoteCanvas(presenter = canvas, surface = model.surface, pictureView = pictureView, modifier = Modifier.fillMaxSize().displayCutoutPadding())
                val shown = ChromePolicy.cursorShown(prefs.interaction, state.pictureState, state.showsMosaic)
                MosaicChrome(state, canvasState, canvas, presenters.sources, Modifier.fillMaxSize().displayCutoutPadding())
                canvasState.picture?.takeIf { shown }?.let { CursorGlyph(cursor, it, Modifier.displayCutoutPadding()) }
                RemoteChrome(chrome, handlers, panel = { RemotePanel(it, panelContext) })
            }
            KeyboardBridge(presenter = keyboard, shown = screen.keyboardShown)
            RemoteDialogs(model, screen, actions, customMacros, lastHostName)
        }
    }
}

private class SessionPresenters(
    val tracker: PointerTracker,
    val canvas: RemoteCanvasPresenter,
    val keyboard: KeyboardPresenter,
    val sources: SourcesPresenter,
    val quality: QualitySheetPresenter,
    val actions: RemoteActions,
    val follower: TextFieldFollower,
)

@Composable
private fun rememberSessionPresenters(
    model: RemoteModel,
    state: RemoteUiState,
    prefs: DevicePrefs,
    screen: SessionScreenState,
    scope: CoroutineScope,
): SessionPresenters {
    val prefsNow = rememberUpdatedState(prefs)
    val stateNow = rememberUpdatedState(state)
    return remember(model) {
        val tracker = PointerTracker(MosaicGate(model.commands) { stateNow.value.showsMosaic }) { pointerSize(stateNow.value) }
        val input = ObserveGate(tracker) { prefsNow.value.interaction == InputMode.OBSERVE }
        val canvas = RemoteCanvasPresenter(input, prefsNow.value.interaction) { tracker.position.value }
        val keyboard = KeyboardPresenter(input) { prefsNow.value.keyboardMode }
        SessionPresenters(
            tracker = tracker,
            canvas = canvas,
            keyboard = keyboard,
            sources = SourcesPresenter(input),
            quality = QualitySheetPresenter(model.quality, scope, onNeedsUpgrade = model::onRelayUpgradeRequested),
            actions = RemoteActions(model, input, screen, canvas, keyboard, { prefsNow.value }, { pointerSize(stateNow.value) }, scope),
            follower = TextFieldFollower(),
        )
    }
}

private fun sessionOverlay(state: RemoteUiState, hostName: String?): SessionOverlayState =
    SessionOverlayState.of(
        hostName = hostName,
        latencyMs = state.latencyMs,
        path = state.path,
        picture = state.pictureState,
        reconnecting = state.reconnecting,
        relayMinutesLeft = state.relayMinutesLeft,
    )

@Composable
private fun SessionEffects(
    state: RemoteUiState,
    prefs: DevicePrefs,
    screen: SessionScreenState,
    canvas: RemoteCanvasPresenter,
    tracker: PointerTracker,
    keyboard: KeyboardPresenter,
    follower: TextFieldFollower,
) {
    LaunchedEffect(prefs.interaction) {
        canvas.setMode(prefs.interaction)
        if (prefs.interaction != InputMode.OBSERVE) screen.lastControl = prefs.interaction
    }
    LaunchedEffect(state.hostPointer) { state.hostPointer?.let { tracker.report(it.point) } }
    LaunchedEffect(state.mosaic) { canvas.setMosaic(state.mosaic) }
    // A focus that moved while another mode was up is stale, so it does not open the keyboard on arrival.
    val focusOnArrival = remember { state.hostTextFocus?.serial }
    LaunchedEffect(state.hostTextFocus?.serial) {
        val focus = state.hostTextFocus?.takeIf { it.serial != focusOnArrival } ?: return@LaunchedEffect
        keyboard.onHostFocusMoved()
        val move = follower.onFocus(
            editable = focus.isEditable,
            enabled = prefs.opensKeyboardForTextFields,
            observing = prefs.interaction == InputMode.OBSERVE,
            mosaic = state.showsMosaic,
            panelOpen = screen.openPanel != null,
            keyboardShown = screen.keyboardShown,
        )
        when (move) {
            KeyboardMove.OPEN -> screen.toggleKeyboard()
            KeyboardMove.CLOSE -> screen.hideKeyboard()
            KeyboardMove.NONE -> Unit
        }
    }
    LaunchedEffect(state.hostField?.serial) {
        val field = state.hostField ?: return@LaunchedEffect
        keyboard.onHostField(field.state.text)
        while (true) {
            delay(keyboard.hostFieldWait() ?: break)
            keyboard.releaseHostField()
        }
    }
    LaunchedEffect(state.picturePixels, prefs.fillsScreen) {
        canvas.onPictureChanged(state.picturePixels)
        if (prefs.fillsScreen) canvas.fillCanvas() else canvas.fitToCanvas()
    }
}

/** Copies the picture and hands it to the system's share sheet, which also offers saving it. Stays on the phone. */
@Composable
private fun shareScreenshot(pictureView: PictureViewHolder, scope: CoroutineScope): () -> Unit {
    val context = LocalContext.current
    return {
        scope.launch {
            val window = context.findActivity()?.window
            val png = window?.let { PictureShot.png(pictureView.view, it) }
            val shared = png != null && FileShare.share(context, ShareRequest("Peering screenshot.png", png, "image/png"), context.getString(R.string.remote_screenshot_share))
            if (!shared) Toast.makeText(context, R.string.remote_screenshot_failed, Toast.LENGTH_SHORT).show()
        }
    }
}

/** Tells the computer which way the phone is held, so it can shape what it sends. A host that did not declare it is not sent it. */
@Composable
private fun ReportOrientation(model: RemoteModel, ready: Boolean) {
    val landscape = LocalConfiguration.current.orientation == Configuration.ORIENTATION_LANDSCAPE
    LaunchedEffect(landscape, ready) {
        if (ready) model.commands.send(ReportDeviceOrientation(landscape))
    }
}

@Composable
private fun rememberStatusPill(model: RemoteModel, scope: CoroutineScope, ready: Boolean): StatusPillPresenter {
    val pill = remember { StatusPillPresenter(scope, memory = model.statusPillMemory) }
    LaunchedEffect(ready) { pill.onReady(ready) }
    return pill
}

@Composable
private fun RemoteBackHandler(screen: SessionScreenState) {
    BackHandler {
        when (screen.backStep()) {
            BackStep.CLOSE_PANEL -> screen.closePanel()
            BackStep.HIDE_KEYBOARD -> screen.hideKeyboard()
            BackStep.ASK_TO_LEAVE -> screen.leaveAsked = true
        }
    }
}
