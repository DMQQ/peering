package pl.dmq.peering.feature.paywall

import java.time.LocalDate

/** Relay seconds used on one calendar day of the phone's zone. */
data class DailyRelayUsage(val day: LocalDate, val seconds: Long)

/** Today's use of the free relay time, as pure arithmetic: a day with no record is a day with nothing used. */
object RelayUsageLedger {
    fun usedOn(stored: DailyRelayUsage?, today: LocalDate): Long =
        if (stored != null && stored.day == today) stored.seconds else 0L

    fun added(stored: DailyRelayUsage?, today: LocalDate, seconds: Long): DailyRelayUsage =
        DailyRelayUsage(today, usedOn(stored, today) + seconds)

    /** The relay refused the session for quota, so the free time of [today] is taken whatever this phone counted. */
    fun spent(today: LocalDate): DailyRelayUsage = DailyRelayUsage(today, FREE_DAILY_RELAY_SECONDS)
}
