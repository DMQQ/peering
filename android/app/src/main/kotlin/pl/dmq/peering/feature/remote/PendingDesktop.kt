package pl.dmq.peering.feature.remote

import pl.dmq.peering.wire.SpaceDisplay

/**
 * A desktop this phone has asked the computer to show, while the computer's own list has yet to say so. The list is
 * coalesced by up to three seconds, in which the tapped tile would still be drawn as the desktop left and read as a tap
 * that did not land.
 */
data class PendingDesktop(val display: Long, val index: Int) {
    companion object {
        /** Longer than the host's coalescing plus the enumeration, so the mark is given up when the answer arrives, not just before. A refusal is silent. */
        const val TIMEOUT_MILLIS = 6_000L
    }
}

/** Whether desktop [index] is where [display] is, with a pending tap on that display answering for it until the computer does. */
fun desktopIsCurrent(display: SpaceDisplay, index: Int, pending: PendingDesktop?): Boolean =
    if (pending != null && pending.display == display.displayId) pending.index == index else display.current == index

/** The desktop the picture is on: the screen it shows is this display and that display is on this desktop. */
fun desktopIsLive(showing: Boolean, display: SpaceDisplay, index: Int, pending: PendingDesktop?): Boolean =
    showing && desktopIsCurrent(display, index, pending)

/** The screen's name is drawn above its desktops with more than one screen, or when it is the one shown and a full screen app hides its current desktop. */
fun namesScreen(screenCount: Int, showing: Boolean, display: SpaceDisplay): Boolean =
    screenCount > 1 || (showing && display.current == null)
