package pl.dmq.peering.feature.remote

import pl.dmq.peering.wire.Modifiers

/** The modifier keys on the bar, with the left-hand macOS keycode the phone presses for them. */
enum class StickyModifier(val keyCode: Int, val bit: Long) {
    SHIFT(56, Modifiers.SHIFT),
    CONTROL(59, Modifiers.CONTROL),
    OPTION(58, Modifiers.OPTION),
    COMMAND(55, Modifiers.COMMAND),
}
