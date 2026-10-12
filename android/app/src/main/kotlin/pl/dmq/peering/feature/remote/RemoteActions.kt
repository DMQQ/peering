package pl.dmq.peering.feature.remote

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import pl.dmq.peering.feature.settings.DevicePrefs
import pl.dmq.peering.wire.JoystickMove
import pl.dmq.peering.wire.LockScreen
import pl.dmq.peering.wire.Modifiers
import pl.dmq.peering.wire.MouseButton
import pl.dmq.peering.wire.MouseDown
import pl.dmq.peering.wire.MouseUp
import pl.dmq.peering.wire.PushClipboard
import pl.dmq.peering.wire.RequestClipboard
import pl.dmq.peering.wire.Scroll
import pl.dmq.peering.wire.SetPrivacyMode

/**
 * What every control of the session screen does, in one place. [input] is the gated sink, so while observing a touch or a
 * key never reaches the computer. The screen builds its handlers from this and holds no logic of its own.
 */
class RemoteActions(
    private val model: RemoteModel,
    private val input: CommandSink,
    private val screen: SessionScreenState,
    private val canvas: RemoteCanvasPresenter,
    private val keyboard: KeyboardPresenter,
    private val prefs: () -> DevicePrefs,
    private val pointSize: () -> Pair<Double, Double>,
    private val scope: CoroutineScope,
) {
    private var badge: Job? = null

    fun sendKey(keyCode: Int, modifiers: Long = 0L) = keyboard.sendKey(keyCode, modifiers)

    fun lock() = input.send(LockScreen)

    fun toggleDark() {
        screen.darkened = !screen.darkened
        input.send(SetPrivacyMode(screen.darkened))
    }

    fun toggleFill() {
        model.prefs.update { it.copy(fillsScreen = !it.fillsScreen) }
    }

    /** Observing and the control mode last used, one after the other. */
    fun toggleMode() {
        val current = prefs().interaction
        screen.lastControl = InputModes.controlModeAfter(current, screen.lastControl)
        model.prefs.update { it.copy(interaction = InputModes.toggled(current, screen.lastControl)) }
    }

    /** One notch of the wheel: it scrolls the computer, or zooms the picture while observing. */
    fun wheelNotch(notches: Int) {
        if (prefs().interaction == InputMode.OBSERVE) {
            canvas.zoomByNotch(-notches)
        } else {
            input.send(Scroll(0.0, notches * ScrollNotch.PIXELS))
        }
    }

    fun joystickMove(dx: Double, dy: Double) {
        input.send(JoystickMove(dx * screen.speed, dy * screen.speed))
    }

    fun click(button: MouseButton) {
        input.send(MouseDown(button))
        input.send(MouseUp(button))
    }

    fun stepSpeed() {
        screen.speed = JoystickMath.nextSpeed(screen.speed)
        screen.speedBadge = JoystickMath.speedLabel(screen.speed)
        badge?.cancel()
        badge = scope.launch {
            delay(BADGE_MILLIS)
            screen.speedBadge = null
        }
    }

    fun paste(text: String) {
        input.send(PushClipboard(text))
        keyboard.sendKey(PASTE_KEY, Modifiers.COMMAND)
    }

    fun send(text: String) = input.send(PushClipboard(text))

    fun requestHostClipboard() = input.send(RequestClipboard)

    fun runMacro(macro: Macro) = keyboard.sendKey(macro.keyCode, macro.modifiers)

    /** The pointer's size in the computer's points, which the joystick's speed is measured against. */
    fun pointerSize(): Pair<Double, Double> = pointSize()

    private companion object {
        const val BADGE_MILLIS = 1_100L
        const val PASTE_KEY = 9
    }
}
