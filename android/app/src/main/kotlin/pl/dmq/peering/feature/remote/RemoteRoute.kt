package pl.dmq.peering.feature.remote

import android.os.SystemClock
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
import kotlin.math.ln
import kotlin.math.roundToInt
import kotlinx.coroutines.CoroutineScope
import pl.dmq.peering.feature.settings.DevicePrefs
import pl.dmq.peering.testing.RemoteBridge
import pl.dmq.peering.ui.kit.LocalBorderless
import pl.dmq.peering.wire.MouseButton
import pl.dmq.peering.wire.SetCaptureSource

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
    val canvasState by canvas.state.collectAsState()
    val cursor by presenters.tracker.position.collectAsState()
    val typed by keyboard.typedPreview.collectAsState()
    val latches by keyboard.latches.collectAsState()
    var lastHostName by rememberSaveable { mutableStateOf<String?>(null) }
    state.hostName?.let { lastHostName = it }
    val overlay = sessionOverlay(state, lastHostName)
    SessionEffects(state, prefs, screen, canvas, presenters.tracker)
    val pill = rememberStatusPill(model, scope, ready = state.hostName != null)
    SessionWindow()
    RemoteBridge(screen, pill, actions, model.clipboard)
    RemoteBackHandler(screen)
    val handlers = chromeHandlers(model, screen, pill, actions, canvas, keyboard, typed, latches)
    val chrome = chromeState(state, prefs, screen, overlay, pill, canvasState.viewport.zoom)
    val panelContext = PanelContext(model, state, prefs, screen, actions, keyboard, presenters.sources, presenters.quality, customMacros, overlay)

    CompositionLocalProvider(LocalBorderless provides true) {
        Box(modifier = Modifier.fillMaxSize().background(Color.Black)) {
            Box(modifier = Modifier.fillMaxSize().imePadding()) {
                RemoteCanvas(presenter = canvas, surface = model.surface, modifier = Modifier.fillMaxSize().displayCutoutPadding())
                val shown = ChromePolicy.cursorShown(prefs.interaction, state.pictureState, state.showsMosaic)
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
) {
    LaunchedEffect(prefs.interaction) {
        canvas.setMode(prefs.interaction)
        if (prefs.interaction != InputMode.OBSERVE) screen.lastControl = prefs.interaction
    }
    LaunchedEffect(state.hostPointer) { state.hostPointer?.let { tracker.report(it.point) } }
    LaunchedEffect(state.mosaic) { canvas.setMosaic(state.mosaic) }
    LaunchedEffect(state.picturePixels, prefs.fillsScreen) {
        canvas.onPictureChanged(state.picturePixels)
        if (prefs.fillsScreen) canvas.fillCanvas() else canvas.fitToCanvas()
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

private fun chromeState(
    state: RemoteUiState,
    prefs: DevicePrefs,
    screen: SessionScreenState,
    overlay: SessionOverlayState,
    pill: StatusPillPresenter,
    zoom: Double,
): ChromeState = ChromeState(
    shown = ChromePolicy.shown(screen.immersive, state.pictureState, state.reconnecting),
    immersive = screen.immersive,
    overlay = overlay,
    status = StatusUi(
        overlay = overlay,
        sourceTitle = state.sourceTitle,
        mosaicWindows = state.mosaic?.tiles?.size,
        darkened = screen.darkened,
        fills = prefs.fillsScreen,
        zoomPercent = (zoom * 100).roundToInt().takeIf { it > ZOOMED_PERCENT },
        hubTabs = HubPresenter().offeredTabs(state.capabilities),
    ),
    statusExpanded = pill.expanded,
    openPanel = screen.openPanel,
    keyboardShown = screen.keyboardShown,
    dockExpanded = screen.dockExpanded,
    interaction = prefs.interaction,
    profile = ApplicationProfiles.forBundle(state.sourceBundleId),
    wheelPosition = if (prefs.interaction == InputMode.OBSERVE) zoomPosition(zoom) else null,
    speedText = screen.speedBadge,
    mosaic = state.showsMosaic,
)

@Composable
private fun chromeHandlers(
    model: RemoteModel,
    screen: SessionScreenState,
    pill: StatusPillPresenter,
    actions: RemoteActions,
    canvas: RemoteCanvasPresenter,
    keyboard: KeyboardPresenter,
    typed: String,
    latches: Map<StickyModifier, ModifierLatch>,
): ChromeHandlers = ChromeHandlers(
    status = StatusActions(
        onLock = { pill.onInteraction(); actions.lock() },
        onToggleDark = { pill.onInteraction(); actions.toggleDark() },
        onToggleFill = { pill.onInteraction(); actions.toggleFill() },
        onResetZoom = { pill.onInteraction(); canvas.fitToCanvas() },
        onImmersive = {
            pill.collapse()
            screen.enterImmersive()
        },
        onStepAway = model::onStepAway,
        onOpenHub = { model.onHubEntry(HubEntry.HUB) },
        onQuit = { model.onHubEntry(HubEntry.DISCONNECT) },
    ),
    onPillTap = pill::onTap,
    onReveal = screen::leaveImmersive,
    onRetry = model::onRetryPicture,
    onPanel = screen::togglePanel,
    onKeyboard = screen::toggleKeyboard,
    onDockExpanded = { screen.dockExpanded = it },
    onKey = actions::sendKey,
    onDelete = keyboard::onSoftKeyboardDelete,
    onChord = { action -> if (action.confirms) screen.quitAsked = true else actions.sendKey(action.keyCode, action.modifiers) },
    onMode = actions::toggleMode,
    onNotch = actions::wheelNotch,
    pointer = pointerActions(actions, keyboard),
    keyboardKeys = KeyboardKeys(
        latches = latches,
        typed = typed,
        onHide = screen::hideKeyboard,
        onModifier = { keyboard.onModifierTap(it, SystemClock.uptimeMillis()) },
        onKey = actions::sendKey,
        onEnter = keyboard::pressEnter,
        onDelete = keyboard::onSoftKeyboardDelete,
    ),
)

private fun pointerActions(actions: RemoteActions, keyboard: KeyboardPresenter): PointerActions =
    PointerActions(
        onBack = { actions.sendKey(LEFT, pl.dmq.peering.wire.Modifiers.COMMAND) },
        onEnter = keyboard::pressEnter,
        joystick = JoystickActions(
            onMove = actions::joystickMove,
            onTap = { actions.click(MouseButton.LEFT) },
            onRightClick = { actions.click(MouseButton.RIGHT) },
            onDoubleTap = actions::stepSpeed,
        ),
        pointWidth = actions.pointerSize().first,
        pointHeight = actions.pointerSize().second,
    )

/**
 * The picture's size in the computer's points, which the joystick's travel and the drawn cursor are both measured in.
 * The catalogue reports a MacBook's display in points already (1512 wide) and a larger one in pixels, so only a size past
 * [MAX_POINT_WIDTH] is halved. Halving always made the drawn cursor run twice as far as the real pointer.
 */
private fun pointerSize(state: RemoteUiState): Pair<Double, Double> =
    state.picturePixels?.let {
        val perPoint = if (it.width > MAX_POINT_WIDTH) 2.0 else 1.0
        (it.width / perPoint) to (it.height / perPoint)
    } ?: (DEFAULT_WIDTH to DEFAULT_HEIGHT)

/** Where [zoom] sits on the wheel's gauge, 0 at the least and 1 at the most, on a log scale. */
private fun zoomPosition(zoom: Double): Float =
    (ln(zoom) / ln(CanvasViewport.MAX_ZOOM)).coerceIn(0.0, 1.0).toFloat()

private const val ZOOMED_PERCENT = 101
private const val MAX_POINT_WIDTH = 2560.0
private const val DEFAULT_WIDTH = 1440.0
private const val DEFAULT_HEIGHT = 900.0
