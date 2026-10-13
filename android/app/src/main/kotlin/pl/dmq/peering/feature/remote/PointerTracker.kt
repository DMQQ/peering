package pl.dmq.peering.feature.remote

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import pl.dmq.peering.wire.JoystickMove
import pl.dmq.peering.wire.MouseMove
import pl.dmq.peering.wire.NormalizedPoint
import pl.dmq.peering.wire.RemoteCommand

/**
 * Passes commands on and keeps the client's own copy of where the computer's pointer is, which is what the cursor glyph
 * draws. A touch sends an absolute position, so it replaces the copy; the joystick sends a delta, so the copy advances by
 * the same amount in the same units. It drifts only when the real pointer stops at a screen edge while the thumb keeps
 * pushing, and the next touch corrects it, as does the computer's own report. [pointSize] is the picture's size in the computer's points.
 */
class PointerTracker(
    private val target: CommandSink,
    private val nowNanos: () -> Long = System::nanoTime,
    private val pointSize: () -> Pair<Double, Double>,
) : CommandSink {
    private var lastNudgeAt: Long? = null
    private val mutablePosition = MutableStateFlow(NormalizedPoint(0.5, 0.5))
    val position: StateFlow<NormalizedPoint> = mutablePosition.asStateFlow()

    override fun send(command: RemoteCommand) {
        when (command) {
            is MouseMove -> mutablePosition.value = command.to.clamped()
            is JoystickMove -> {
                lastNudgeAt = nowNanos()
                advance(command.dx, command.dy)
            }
            else -> Unit
        }
        target.send(command)
    }

    /**
     * The computer said where its pointer is, which beats the copy kept here. Not while the joystick is driving: the
     * computer's watcher mistakes a few of its own steps for a hand, and a report is a round trip old, so applying one
     * pulls the drawn cursor back to mid-drag. The position it sends once the joystick has been still arrives after the window.
     */
    fun report(point: NormalizedPoint) {
        val last = lastNudgeAt
        if (last != null && nowNanos() - last < QUIET_AFTER_NUDGE_NANOS) return
        mutablePosition.value = point.clamped()
    }

    private fun advance(dx: Double, dy: Double) {
        val (width, height) = pointSize()
        if (width <= 0 || height <= 0) return
        val current = mutablePosition.value
        mutablePosition.value = NormalizedPoint(current.x + dx / width, current.y + dy / height).clamped()
    }

    private companion object {
        const val QUIET_AFTER_NUDGE_NANOS = 250_000_000L
    }
}
