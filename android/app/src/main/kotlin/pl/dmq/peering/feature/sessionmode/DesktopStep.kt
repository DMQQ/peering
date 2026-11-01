package pl.dmq.peering.feature.sessionmode

import pl.dmq.peering.wire.RemoteCommand
import pl.dmq.peering.wire.SpaceDirection
import pl.dmq.peering.wire.SpaceDisplay
import pl.dmq.peering.wire.SwitchSpace
import pl.dmq.peering.wire.SwitchToSpace

/**
 * Moving a desktop either way from the one the computer reports as current. The relative chord stands in only when no
 * desktop list came, since it moves from wherever the system thinks it is rather than from the desktop being shown.
 */
object DesktopStep {
    fun command(display: SpaceDisplay?, step: Int): RemoteCommand? {
        val current = display?.current
        if (display == null || current == null || display.count <= 0) {
            return SwitchSpace(if (step < 0) SpaceDirection.LEFT else SpaceDirection.RIGHT)
        }
        val target = (current + step).coerceIn(1, display.count)
        return if (target == current) null else SwitchToSpace(display.displayId, target)
    }
}
