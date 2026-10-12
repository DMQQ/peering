package pl.dmq.peering.feature.sessions

import pl.dmq.peering.feature.paywall.RelayAllowance

/** The relay card's bar: how much of today's free time is left, and whether it is low enough to say so. */
data class RelayMeter(val remainingFraction: Float, val low: Boolean) {
    companion object {
        /** A quarter or less of the day's time counts as low. */
        const val LOW_FRACTION = 0.25f

        /** Null for a paid plan, which has no meter. */
        fun of(allowance: RelayAllowance): RelayMeter? {
            if (allowance.paid || allowance.dailyLimitSeconds <= 0) return null
            val fraction = (allowance.remainingSeconds.toFloat() / allowance.dailyLimitSeconds).coerceIn(0f, 1f)
            return RelayMeter(fraction, low = fraction <= LOW_FRACTION)
        }
    }
}
