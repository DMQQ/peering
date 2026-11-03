package pl.dmq.peering.feature.sessionmode

import kotlin.math.abs
import pl.dmq.peering.wire.KeyDown
import pl.dmq.peering.wire.KeyUp
import pl.dmq.peering.wire.Modifiers
import pl.dmq.peering.wire.RemoteCommand
import pl.dmq.peering.wire.SpaceDisplay

/** The way a three or four finger swipe on the trackpad went, read once when the fingers lift. */
enum class TrackpadSwipe {
    LEFT, RIGHT, UP, DOWN;

    companion object {
        /** The longer axis decides, so a swipe drawn at an angle still counts. Below [minimum] it is no swipe. `dy` grows downwards. */
        fun of(dx: Double, dy: Double, minimum: Double): TrackpadSwipe? {
            if (maxOf(abs(dx), abs(dy)) < minimum) return null
            return if (abs(dx) >= abs(dy)) {
                if (dx < 0) LEFT else RIGHT
            } else {
                if (dy < 0) UP else DOWN
            }
        }
    }
}

/**
 * As on a Mac trackpad: left or right moves a desktop (the content follows the fingers), up opens Mission Control, down
 * shows the app's windows. A host without desktops gets nothing, since the chords mean something else there.
 */
fun TrackpadSwipe.commands(display: SpaceDisplay?, desktops: Boolean): List<RemoteCommand> = if (!desktops) emptyList() else when (this) {
    TrackpadSwipe.LEFT -> listOfNotNull(DesktopStep.command(display, 1))
    TrackpadSwipe.RIGHT -> listOfNotNull(DesktopStep.command(display, -1))
    TrackpadSwipe.UP -> controlChord(UP_ARROW)
    TrackpadSwipe.DOWN -> controlChord(DOWN_ARROW)
}

private fun controlChord(keyCode: Int): List<RemoteCommand> =
    listOf(KeyDown(keyCode, Modifiers(Modifiers.CONTROL)), KeyUp(keyCode, Modifiers(Modifiers.CONTROL)))

private const val UP_ARROW = 126
private const val DOWN_ARROW = 125
