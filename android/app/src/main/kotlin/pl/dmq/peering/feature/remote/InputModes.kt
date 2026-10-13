package pl.dmq.peering.feature.remote

object InputModes {
    /** The dock's mode button: observing, or back to the control mode the user was in. */
    fun toggled(current: InputMode, lastControl: InputMode): InputMode =
        if (current == InputMode.OBSERVE) lastControl else InputMode.OBSERVE

    /** The control mode to go back to: [current] unless it is observing, which keeps the one before. */
    fun controlModeAfter(current: InputMode, previous: InputMode): InputMode =
        if (current == InputMode.OBSERVE) previous else current
}
