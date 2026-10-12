package pl.dmq.peering.feature.paywall

/** Remaining relay time in the form the screens word: none, under a minute, whole minutes, or hours and minutes. */
sealed interface RemainingLabel {
    data object None : RemainingLabel

    data object UnderAMinute : RemainingLabel

    data class Minutes(val minutes: Int) : RemainingLabel

    data class HoursAndMinutes(val hours: Int, val minutes: Int) : RemainingLabel

    companion object {
        private const val SECONDS_PER_MINUTE = 60L
        private const val SECONDS_PER_HOUR = 3_600L

        fun of(seconds: Long): RemainingLabel = when {
            seconds <= 0 -> None
            seconds < SECONDS_PER_MINUTE -> UnderAMinute
            seconds < SECONDS_PER_HOUR -> Minutes((seconds / SECONDS_PER_MINUTE).toInt())
            else -> HoursAndMinutes(
                hours = (seconds / SECONDS_PER_HOUR).toInt(),
                minutes = ((seconds % SECONDS_PER_HOUR) / SECONDS_PER_MINUTE).toInt(),
            )
        }
    }
}
