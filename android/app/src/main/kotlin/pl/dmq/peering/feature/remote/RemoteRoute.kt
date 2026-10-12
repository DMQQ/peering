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
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import kotlin.math.ln
import kotlin.math.roundToInt
import kotlinx.coroutines.delay
import pl.dmq.peering.wire.MouseButton

/** The remote screen for a connected computer: the picture, the chrome over it, the panels, and the keyboard. */
@Composable
fun RemoteRoute(model: RemoteModel) {
    val state by model.state.collectAsState()
    val prefs by model.prefs.prefs.collectAsState()
    val customMacros by model.macros.custom.collectAsState()
    val screen = rememberSaveable(saver = SessionScreenState.Saver) { SessionScreenState() }
    val scope = rememberCoroutineScope()
    val prefsNow = rememberUpdatedState(prefs)
    val stateNow = rememberUpdatedState(state)
    val input = remember(model) { ObserveGate(model.commands) { prefsNow.value.interaction == InputMode.OBSERVE } }
    val canvas = remember(model) { RemoteCanvasPresenter(input, prefsNow.value.interaction) }
    val keyboard = remember(model) { KeyboardPresenter(input) { prefsNow.value.keyboardMode } }
    val sources = remember(model) { SourcesPresenter(input) }
    val quality = remember(model) { QualitySheetPresenter(model.quality, scope, onNeedsUpgrade = model::onRelayUpgradeRequested) }
    val actions = remember(model) {
        RemoteActions(model, input, screen, canvas, keyboard, { prefsNow.value }, { pointerSize(stateNow.value) }, scope)
    }
    val canvasState by canvas.state.collectAsState()
    val typed by keyboard.typedPreview.collectAsState()
    val latches by keyboard.latches.collectAsState()
    var lastHostName by rememberSaveable { mutableStateOf<String?>(null) }
    state.hostName?.let { lastHostName = it }

    val overlay = SessionOverlayState.of(
        hostName = lastHostName,
        latencyMs = state.latencyMs,
        path = state.path,
        picture = state.pictureState,
        reconnecting = state.reconnecting,
        relayMinutesLeft = state.relayMinutesLeft,
    )
    val zoomPercent = (canvasState.viewport.zoom * 100).roundToInt().takeIf { it > ZOOMED_PERCENT }

    LaunchedEffect(prefs.interaction) {
        canvas.setMode(prefs.interaction)
        if (prefs.interaction != InputMode.OBSERVE) screen.lastControl = prefs.interaction
    }
    LaunchedEffect(state.picturePixels, prefs.fillsScreen) {
        canvas.onPictureChanged(state.picturePixels)
        if (prefs.fillsScreen) canvas.fillCanvas() else canvas.fitToCanvas()
    }
    val ready = state.hostName != null
    LaunchedEffect(ready) { if (ready) screen.statusExpanded = true }
    var touches by remember { mutableStateOf(0) }
    LaunchedEffect(screen.statusExpanded, touches) {
        if (screen.statusExpanded) {
            delay(STATUS_OPEN_MILLIS)
            screen.statusExpanded = false
        }
    }

    SessionWindow()
    BackHandler {
        when (screen.backStep()) {
            BackStep.CLOSE_PANEL -> screen.closePanel()
            BackStep.HIDE_KEYBOARD -> screen.hideKeyboard()
            BackStep.ASK_TO_LEAVE -> screen.leaveAsked = true
        }
    }

    val handlers = chromeHandlers(model, screen, actions, canvas, keyboard, typed, latches) { touches++ }
    val chrome = ChromeState(
        shown = ChromePolicy.shown(screen.immersive, state.pictureState, state.reconnecting),
        immersive = screen.immersive,
        overlay = overlay,
        status = StatusUi(
            overlay = overlay,
            sourceTitle = state.sourceTitle,
            darkened = screen.darkened,
            fills = prefs.fillsScreen,
            zoomPercent = zoomPercent,
            terminalEntries = HubPresenter().terminalEntries(state.capabilities),
        ),
        statusExpanded = screen.statusExpanded,
        openPanel = screen.openPanel,
        keyboardShown = screen.keyboardShown,
        dockExpanded = screen.dockExpanded,
        interaction = prefs.interaction,
        profile = ApplicationProfiles.forBundle(state.sourceBundleId),
        wheelPosition = if (prefs.interaction == InputMode.OBSERVE) zoomPosition(canvasState.viewport.zoom) else null,
        speedText = screen.speedBadge,
    )
    val panelContext = PanelContext(model, state, prefs, screen, actions, keyboard, sources, quality, customMacros, overlay)

    Box(modifier = Modifier.fillMaxSize().background(Color.Black)) {
        Box(modifier = Modifier.fillMaxSize().imePadding()) {
            RemoteCanvas(presenter = canvas, surface = model.surface, modifier = Modifier.fillMaxSize().displayCutoutPadding())
            RemoteChrome(chrome, handlers, panel = { RemotePanel(it, panelContext) })
        }
        KeyboardBridge(presenter = keyboard, shown = screen.keyboardShown)
        RemoteDialogs(model, screen, actions, customMacros, lastHostName)
    }
}

@Composable
private fun chromeHandlers(
    model: RemoteModel,
    screen: SessionScreenState,
    actions: RemoteActions,
    canvas: RemoteCanvasPresenter,
    keyboard: KeyboardPresenter,
    typed: String,
    latches: Map<StickyModifier, ModifierLatch>,
    onTouch: () -> Unit,
): ChromeHandlers = ChromeHandlers(
    status = StatusActions(
        onLock = { onTouch(); actions.lock() },
        onToggleDark = { onTouch(); actions.toggleDark() },
        onToggleFill = { onTouch(); actions.toggleFill() },
        onResetZoom = { onTouch(); canvas.fitToCanvas() },
        onImmersive = screen::enterImmersive,
        onStepAway = model::onStepAway,
        onTerminalEntry = model::onHubEntry,
        onQuit = { screen.leaveAsked = true },
    ),
    onStatusExpanded = { screen.statusExpanded = it },
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
    pointer = PointerActions(
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
    ),
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

/** The picture's size in the computer's points: its pixels over two, the factor of a Retina screen, or a laptop's size before the catalogue says. */
private fun pointerSize(state: RemoteUiState): Pair<Double, Double> =
    state.picturePixels?.let { (it.width / PIXELS_PER_POINT) to (it.height / PIXELS_PER_POINT) } ?: (DEFAULT_WIDTH to DEFAULT_HEIGHT)

/** Where [zoom] sits on the wheel's gauge, 0 at the least and 1 at the most, on a log scale. */
private fun zoomPosition(zoom: Double): Float =
    (ln(zoom) / ln(CanvasViewport.MAX_ZOOM)).coerceIn(0.0, 1.0).toFloat()

private const val ZOOMED_PERCENT = 101
private const val STATUS_OPEN_MILLIS = 2_500L
private const val PIXELS_PER_POINT = 2.0
private const val DEFAULT_WIDTH = 1440.0
private const val DEFAULT_HEIGHT = 900.0
