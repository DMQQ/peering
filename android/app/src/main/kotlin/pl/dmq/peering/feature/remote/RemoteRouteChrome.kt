package pl.dmq.peering.feature.remote

import android.os.SystemClock
import androidx.compose.runtime.Composable
import kotlin.math.ln
import kotlin.math.roundToInt
import pl.dmq.peering.feature.remote.dictation.VoiceDictation
import pl.dmq.peering.feature.settings.DevicePrefs
import pl.dmq.peering.wire.MouseButton

internal fun chromeState(
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
        screenControls = state.screenControls,
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
internal fun chromeHandlers(
    model: RemoteModel,
    screen: SessionScreenState,
    pill: StatusPillPresenter,
    actions: RemoteActions,
    canvas: RemoteCanvasPresenter,
    keyboard: KeyboardPresenter,
    typed: String,
    latches: Map<StickyModifier, ModifierLatch>,
    follower: TextFieldFollower,
    dictation: VoiceDictation,
    onScreenshot: () -> Unit,
): ChromeHandlers = ChromeHandlers(
    status = StatusActions(
        onLock = { pill.onInteraction(); actions.lock() },
        onToggleDark = { pill.onInteraction(); actions.toggleDark() },
        onToggleFill = { pill.onInteraction(); actions.toggleFill() },
        onScreenshot = { pill.onInteraction(); onScreenshot() },
        onResetZoom = { pill.onInteraction(); canvas.fitToCanvas() },
        onImmersive = {
            pill.collapse()
            screen.enterImmersive()
        },
        onStepAway = model::onStepAway,
        onOpenHub = { model.onHubEntry(HubEntry.HUB) },
        onChangeMode = model::onChangeMode,
        onQuit = { model.onHubEntry(HubEntry.DISCONNECT) },
    ),
    onPillTap = pill::onTap,
    onReveal = screen::leaveImmersive,
    onRetry = model::onRetryPicture,
    onPanel = screen::togglePanel,
    onKeyboard = {
        follower.keyboardToggledByHand()
        screen.toggleKeyboard()
    },
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
        onHide = {
            follower.keyboardToggledByHand()
            screen.hideKeyboard()
        },
        onModifier = { keyboard.onModifierTap(it, SystemClock.uptimeMillis()) },
        onKey = actions::sendKey,
        onEnter = keyboard::pressEnter,
        onDelete = keyboard::onSoftKeyboardDelete,
        dictation = dictation,
        onDictated = keyboard::onDictated,
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
 * [MAX_POINT_WIDTH] is halved.
 */
internal fun pointerSize(state: RemoteUiState): Pair<Double, Double> =
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
