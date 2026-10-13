package pl.dmq.peering.feature.paywall

/** Relay time the free plan gets each day. Paid plans have no daily limit. */
const val FREE_DAILY_RELAY_SECONDS = 30L * 60L

/** How much relay time today has used. [usedSeconds] comes from the session layer; paid access ends the limit. */
data class RelayAllowance(
    val usedSeconds: Long,
    val paid: Boolean,
    val dailyLimitSeconds: Long = FREE_DAILY_RELAY_SECONDS,
) {
    val remainingSeconds: Long get() = (dailyLimitSeconds - usedSeconds).coerceAtLeast(0)

    val isSpent: Boolean get() = !paid && remainingSeconds == 0L
}
