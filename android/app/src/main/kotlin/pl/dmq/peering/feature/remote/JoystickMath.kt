package pl.dmq.peering.feature.remote

import kotlin.math.hypot
import kotlin.math.pow

/** The pointer joystick's arithmetic. Travel is per unit time, not per touch sample, so a 120 Hz screen is no faster. */
object JoystickMath {
    /** Picture widths a second at full deflection and 1x, the iPhone's figure: 1.5 on a straight line put even a light push past what a person can aim with. */
    const val WIDTHS_PER_SECOND_AT_FULL_DEFLECTION = 0.8

    /** Above 1 so the first half of the stick is fine control and the speed arrives at the rim. */
    const val RESPONSE_EXPONENT = 1.6

    /** A gap longer than this is a new gesture: otherwise the first sample would carry all the time since the last. */
    const val MAXIMUM_SAMPLE_GAP_SECONDS = 0.05

    /** The speeds a double tap steps through, and back to the start. */
    val SPEEDS: List<Double> = listOf(1.0, 1.5, 2.0, 2.5, 3.0)

    /** The speed after [current]; one that is not in the list restarts the cycle. */
    fun nextSpeed(current: Double): Double {
        val index = SPEEDS.indexOf(current).takeIf { it >= 0 } ?: 0
        return SPEEDS[(index + 1) % SPEEDS.size]
    }

    fun speedLabel(speed: Double): String = if (speed == Math.rint(speed)) "${speed.toInt()}" else String.format(java.util.Locale.ROOT, "%.1f", speed)

    /** The knob offset kept inside the ring, so a finger wandering off the pad keeps full deflection. */
    fun clamped(x: Double, y: Double, radius: Double): Pair<Double, Double> {
        val distance = hypot(x, y)
        return if (distance > radius && distance > 0) (x * radius / distance) to (y * radius / distance) else x to y
    }

    /** How far the pointer moves, in the picture's own points, for a knob held at ([x], [y]) for [seconds]. */
    fun travel(x: Double, y: Double, radius: Double, pointWidth: Double, pointHeight: Double, seconds: Double): Pair<Double, Double> {
        val interval = seconds.coerceIn(0.0, MAXIMUM_SAMPLE_GAP_SECONDS)
        val deflection = hypot(x, y) / radius
        if (deflection <= 0.0 || !deflection.isFinite()) return 0.0 to 0.0
        val gain = deflection.coerceAtMost(1.0).pow(RESPONSE_EXPONENT) / deflection
        val perSecond = WIDTHS_PER_SECOND_AT_FULL_DEFLECTION * gain * interval
        return (x / radius) * perSecond * pointWidth to (y / radius) * perSecond * pointHeight
    }
}
