package pl.dmq.peering.feature.sessionmode

/**
 * Turns a finger's movement on the glass into the direction the person meant, when the phone is held at an angle the
 * screen did not rotate to (upside down, most often). Orientations are quarter turns counterclockwise from upright
 * portrait: 0 portrait, 1 the top to the left, 2 upside down, 3 the top to the right.
 */
data class TrackpadOrientation(val quarterTurns: Int) {
    /** `dy` grows downwards on the glass and in the result. */
    fun intended(dx: Double, dy: Double): Pair<Double, Double> = when (quarterTurns) {
        1 -> dy to -dx
        2 -> -dx to -dy
        3 -> -dy to dx
        else -> dx to dy
    }

    companion object {
        fun of(device: Int, screen: Int): TrackpadOrientation = TrackpadOrientation(((device - screen) % 4 + 4) % 4)

        /** Android's sensor angle grows clockwise, so a phone with its left side up (90) has its top to the right. Null while it lies flat. */
        fun deviceQuarterTurns(sensorDegrees: Int): Int? {
            if (sensorDegrees < 0) return null
            val clockwise = ((sensorDegrees + 45) / 90) % 4
            return (4 - clockwise) % 4
        }
    }
}
