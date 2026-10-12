package pl.dmq.peering.feature.remote

import android.os.SystemClock
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectVerticalDragGestures
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material3.Icon
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableDoubleStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import kotlin.math.floor
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import pl.dmq.peering.R
import pl.dmq.peering.ui.kit.SessionIcons
import pl.dmq.peering.ui.kit.blockTouches
import pl.dmq.peering.ui.kit.sessionSurface
import pl.dmq.peering.ui.kit.tappable
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PillShape
import pl.dmq.peering.ui.theme.peeringShapes

/**
 * A wheel with detents: chevrons at both ends, a ridged rim between them. A drag rolls it a notch at a time and a flick
 * keeps it coasting. With a [position] it is a gauge instead (the zoom in Observe), a fill rising from the bottom.
 */
@Composable
fun ScrollWheel(
    onNotch: (Int) -> Unit,
    label: String,
    position: Float?,
    modifier: Modifier = Modifier,
) {
    val scope = rememberCoroutineScope()
    val haptics = LocalHapticFeedback.current
    val density = LocalDensity.current
    val wheel = remember { ScrollWheelState() }
    var phase by remember { mutableDoubleStateOf(0.0) }
    var velocity by remember { mutableDoubleStateOf(0.0) }
    var lastSampleMs by remember { mutableLongStateOf(NO_SAMPLE) }
    var spin by remember { mutableStateOfJob() }
    var lastDetentMs by remember { mutableLongStateOf(0L) }
    val isGauge = position != null

    fun detent(spinning: Boolean, now: Long) {
        if (spinning && now - lastDetentMs < DETENT_INTERVAL_MS) return
        lastDetentMs = now
        haptics.performHapticFeedback(HapticFeedbackType.TextHandleMove)
    }

    fun emit(notches: Int, spinning: Boolean) {
        phase = wheel.phase
        if (notches == 0) return
        onNotch(notches)
        detent(spinning, SystemClock.uptimeMillis())
    }

    fun stopSpin() {
        spin?.cancel()
        spin = null
    }

    fun step(notch: Int) {
        stopSpin()
        emit(wheel.seat(), spinning = false)
        emit(wheel.rollNotches(notch.toDouble()), spinning = false)
    }

    fun startSpin(launch: Double) {
        if (isGauge || launch <= WheelSpin.STALLING) return
        stopSpin()
        val started = SystemClock.uptimeMillis()
        val duration = WheelSpin.duration(launch)
        spin = scope.launch {
            while (isActive) {
                delay(SPIN_INTERVAL_MS)
                val elapsed = (SystemClock.uptimeMillis() - started) / MILLIS
                if (elapsed >= duration) return@launch
                emit(wheel.rollNotches(WheelSpin.rate(launch, elapsed) * SPIN_INTERVAL_MS / MILLIS), spinning = true)
            }
        }
    }

    DisposableEffect(isGauge) { onDispose { spin?.cancel() } }

    Column(
        modifier = modifier
            .size(width = ChromeMetrics.panelWidth, height = ChromeMetrics.wheelHeight)
            .sessionSurface(peeringShapes.medium)
            .blockTouches()
            .padding(vertical = 5.dp),
    ) {
        Chevron(SessionIcons.up, stringResource(R.string.remote_wheel_up)) { step(-1) }
        Box(
            Modifier
                .weight(1f)
                .fillMaxWidth()
                .semantics { contentDescription = label }
                .pointerInput(isGauge) {
                    detectVerticalDragGestures(
                        onDragStart = {
                            stopSpin()
                            lastSampleMs = NO_SAMPLE
                            velocity = 0.0
                        },
                        onVerticalDrag = { change, amount ->
                            stopSpin()
                            val points = amount / density.density
                            val now = change.uptimeMillis
                            if (lastSampleMs != NO_SAMPLE) {
                                val interval = (now - lastSampleMs) / MILLIS
                                velocity = if (interval > 0 && interval < REST_GAP_SECONDS) {
                                    velocity + (points / interval - velocity) * VELOCITY_SMOOTHING
                                } else {
                                    0.0
                                }
                            }
                            lastSampleMs = now
                            emit(wheel.roll(points.toDouble()), spinning = false)
                        },
                        onDragEnd = {
                            val resting = lastSampleMs != NO_SAMPLE && SystemClock.uptimeMillis() - lastSampleMs > REST_GAP_SECONDS * MILLIS
                            val speed = if (resting) 0.0 else velocity
                            lastSampleMs = NO_SAMPLE
                            velocity = 0.0
                            emit(wheel.seat(), spinning = false)
                            startSpin(WheelSpin.launch(speed))
                        },
                        onDragCancel = {
                            lastSampleMs = NO_SAMPLE
                            velocity = 0.0
                        },
                    )
                },
            contentAlignment = Alignment.Center,
        ) {
            if (position != null) Gauge(position) else Ridges(phase)
        }
        Chevron(SessionIcons.down, stringResource(R.string.remote_wheel_down)) { step(1) }
    }
}

@Composable
private fun Chevron(icon: ImageVector, description: String, onClick: () -> Unit) {
    Box(Modifier.width(ChromeMetrics.panelWidth).height(22.dp).tappable(onClick), contentAlignment = Alignment.Center) {
        Icon(icon, contentDescription = description, tint = PeeringColors.muted, modifier = Modifier.size(18.dp))
    }
}

@Composable
private fun Ridges(phase: Double) {
    Canvas(Modifier.width(RIM_WIDTH).fillMaxSize().clip(PillShape).background(PeeringColors.surface)) {
        val spacing = RIDGE_SPACING.toPx()
        var y = ((phase - floor(phase)) * spacing).toFloat()
        while (y < size.height) {
            drawRoundRect(
                color = PeeringColors.ink.copy(alpha = 0.5f),
                topLeft = Offset(1.5.dp.toPx(), y),
                size = Size(size.width - 3.dp.toPx(), 1.dp.toPx()),
                cornerRadius = CornerRadius(0.5.dp.toPx()),
            )
            y += spacing
        }
    }
    Box(Modifier.width(RIM_WIDTH + 10.dp).height(2.dp).clip(PillShape).background(PeeringColors.ink))
}

@Composable
private fun Gauge(position: Float) {
    Box(Modifier.width(RIM_WIDTH).fillMaxSize().clip(PillShape).background(PeeringColors.surface), contentAlignment = Alignment.BottomCenter) {
        Box(Modifier.fillMaxWidth().fillMaxHeight(position.coerceIn(0f, 1f).coerceAtLeast(0.1f)).clip(PillShape).background(PeeringColors.accent))
    }
}

private fun mutableStateOfJob() = mutableStateOf<Job?>(null)

private val RIM_WIDTH = 14.dp
private val RIDGE_SPACING = 9.dp
private const val NO_SAMPLE = -1L
private const val SPIN_INTERVAL_MS = 16L
private const val DETENT_INTERVAL_MS = 50L
private const val MILLIS = 1000.0
private const val REST_GAP_SECONDS = 0.06
private const val VELOCITY_SMOOTHING = 0.35
