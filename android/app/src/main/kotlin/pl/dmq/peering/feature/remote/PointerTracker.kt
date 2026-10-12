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
 * pushing, and the next touch corrects it. [pointSize] is the picture's size in the computer's points.
 */
class PointerTracker(
    private val target: CommandSink,
    private val pointSize: () -> Pair<Double, Double>,
) : CommandSink {
    private val mutablePosition = MutableStateFlow(NormalizedPoint(0.5, 0.5))
    val position: StateFlow<NormalizedPoint> = mutablePosition.asStateFlow()

    override fun send(command: RemoteCommand) {
        when (command) {
            is MouseMove -> mutablePosition.value = command.to.clamped()
            is JoystickMove -> advance(command.dx, command.dy)
            else -> Unit
        }
        target.send(command)
    }

    private fun advance(dx: Double, dy: Double) {
        val (width, height) = pointSize()
        if (width <= 0 || height <= 0) return
        val current = mutablePosition.value
        mutablePosition.value = NormalizedPoint(current.x + dx / width, current.y + dy / height).clamped()
    }
}
