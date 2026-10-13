package pl.dmq.peering.feature.remote

import android.os.SystemClock
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.hapticfeedback.HapticFeedback
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.PointerInputScope
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlin.math.hypot
import kotlin.math.roundToInt
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import pl.dmq.peering.R
import pl.dmq.peering.ui.kit.sessionSurface
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText
import pl.dmq.peering.ui.theme.PillShape

/** What the joystick asks of the screen. [onMove] gets travel in the picture's own points. */
class JoystickActions(
    val onMove: (Double, Double) -> Unit,
    val onTap: () -> Unit,
    val onRightClick: () -> Unit,
    val onDoubleTap: () -> Unit,
)

/**
 * A relative pointer: drag nudges the cursor, tap clicks, hold then lift right clicks, a double tap steps the speed
 * (shown as [speedText] for a moment). Deflection means speed, so the cursor keeps moving while the knob is held.
 */
@Composable
fun Joystick(
    actions: JoystickActions,
    pointWidth: Double,
    pointHeight: Double,
    speedText: String?,
    modifier: Modifier = Modifier,
) {
    val scope = rememberCoroutineScope()
    val haptics = LocalHapticFeedback.current
    val radius = with(LocalDensity.current) { ChromeMetrics.joystickRadius.toPx() }
    var knob by remember { mutableStateOf(Offset.Zero) }
    var longPress by remember { mutableStateOf(false) }
    val description = stringResource(R.string.remote_joystick)
    Box(
        modifier = modifier
            .size(ChromeMetrics.joystickRadius * 2)
            .sessionSurface(PillShape)
            .semantics { contentDescription = description }
            .pointerInput(radius, pointWidth, pointHeight) {
                joystickGestures(
                    radius, pointWidth, pointHeight, scope, haptics, actions,
                    onKnob = { knob = it },
                    onLongPress = { longPress = it },
                )
            },
        contentAlignment = Alignment.Center,
    ) {
        Box(
            Modifier
                .offset { IntOffset(knob.x.roundToInt(), knob.y.roundToInt()) }
                .size(40.dp)
                .scale(if (longPress) 1.2f else 1f)
                .clip(PillShape)
                .background(PeeringColors.ink.copy(alpha = 0.85f)),
        )
        if (speedText != null) {
            Text(
                speedText,
                style = PeeringText.subheadline.copy(fontSize = 13.sp, fontWeight = FontWeight.ExtraBold),
                color = PeeringColors.onInk,
                modifier = Modifier.alpha(1f),
            )
        }
    }
}

private suspend fun PointerInputScope.joystickGestures(
    radius: Float,
    pointWidth: Double,
    pointHeight: Double,
    scope: CoroutineScope,
    haptics: HapticFeedback,
    actions: JoystickActions,
    onKnob: (Offset) -> Unit,
    onLongPress: (Boolean) -> Unit,
) {
    val taps = JoystickTapResolver(scope, actions)
    awaitEachGesture {
        awaitFirstDown(requireUnconsumed = false)
        val gesture = JoystickGesture(radius, pointWidth, pointHeight, actions, onKnob, onLongPress)
        val hold = scope.launch {
            delay(LONG_PRESS_MS)
            if (gesture.holdElapsed()) haptics.performHapticFeedback(HapticFeedbackType.LongPress)
        }
        val drain = scope.launch {
            while (isActive) {
                delay(SEND_INTERVAL_MS)
                gesture.flush()
            }
        }
        var change = awaitPointerEventChange()
        while (change.pressed) {
            if (gesture.drag(change.position)) hold.cancel()
            change.consume()
            change = awaitPointerEventChange()
        }
        hold.cancel()
        drain.cancel()
        gesture.release()
        if (gesture.travelled < TAP_MAX_DISPLACEMENT_PX) taps.resolve(gesture.held)
    }
}

/** One touch: the travel not yet sent, and whether it has become a hold or a drag. */
private class JoystickGesture(
    private val radius: Float,
    private val pointWidth: Double,
    private val pointHeight: Double,
    private val actions: JoystickActions,
    private val onKnob: (Offset) -> Unit,
    private val onLongPress: (Boolean) -> Unit,
) {
    var held = false
        private set
    var travelled = 0f
        private set
    private var moved = false
    private var pendingX = 0.0
    private var pendingY = 0.0
    private var lastSample = SystemClock.uptimeMillis()

    fun holdElapsed(): Boolean {
        if (moved) return false
        held = true
        onLongPress(true)
        return true
    }

    fun flush() {
        if (pendingX != 0.0 || pendingY != 0.0) {
            actions.onMove(pendingX, pendingY)
            pendingX = 0.0
            pendingY = 0.0
        }
    }

    /** True once the finger has gone past tap distance, so the hold timer should stop. */
    fun drag(position: Offset): Boolean {
        val raw = position - Offset(radius, radius)
        val pastTap = hypot(raw.x, raw.y) > TAP_MAX_DISPLACEMENT_PX
        if (pastTap) {
            moved = true
            held = false
            onLongPress(false)
        }
        travelled = maxOf(travelled, hypot(raw.x, raw.y))
        val (x, y) = JoystickMath.clamped(raw.x.toDouble(), raw.y.toDouble(), radius.toDouble())
        onKnob(Offset(x.toFloat(), y.toFloat()))
        if (!held) {
            val now = SystemClock.uptimeMillis()
            val (dx, dy) = JoystickMath.travel(x, y, radius.toDouble(), pointWidth, pointHeight, (now - lastSample) / MILLIS)
            lastSample = now
            pendingX += dx
            pendingY += dy
        }
        return pastTap
    }

    fun release() {
        flush()
        onKnob(Offset.Zero)
        onLongPress(false)
    }
}

/** Tells a single tap from a double tap: a tap waits out the double tap window before it clicks. */
private class JoystickTapResolver(private val scope: CoroutineScope, private val actions: JoystickActions) {
    private var lastTapEnded = 0L
    private var pendingClick: Job? = null

    fun resolve(held: Boolean) {
        if (held) {
            actions.onRightClick()
            return
        }
        val now = SystemClock.uptimeMillis()
        if (now - lastTapEnded < DOUBLE_TAP_MS) {
            pendingClick?.cancel()
            lastTapEnded = 0L
            actions.onDoubleTap()
        } else {
            lastTapEnded = now
            pendingClick = scope.launch {
                delay(DOUBLE_TAP_MS)
                actions.onTap()
                lastTapEnded = 0L
            }
        }
    }
}

private suspend fun androidx.compose.ui.input.pointer.AwaitPointerEventScope.awaitPointerEventChange() =
    awaitPointerEvent().changes.first()

private const val LONG_PRESS_MS = 450L
private const val SEND_INTERVAL_MS = 16L
private const val DOUBLE_TAP_MS = 300L
private const val TAP_MAX_DISPLACEMENT_PX = 8f
private const val MILLIS = 1000.0
