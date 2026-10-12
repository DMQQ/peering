package pl.dmq.peering.feature.agents

/** How long ago something happened, in the coarsest unit that reads naturally. */
sealed interface RelativeAge {
    data object JustNow : RelativeAge

    data class Minutes(val count: Int) : RelativeAge

    data class Hours(val count: Int) : RelativeAge

    data class Days(val count: Int) : RelativeAge

    companion object {
        fun between(nowUnix: Long, thenUnix: Long): RelativeAge {
            val seconds = nowUnix - thenUnix
            return when {
                seconds < SECONDS_PER_MINUTE -> JustNow
                seconds < SECONDS_PER_HOUR -> Minutes((seconds / SECONDS_PER_MINUTE).toInt())
                seconds < SECONDS_PER_DAY -> Hours((seconds / SECONDS_PER_HOUR).toInt())
                else -> Days((seconds / SECONDS_PER_DAY).toInt())
            }
        }

        private const val SECONDS_PER_MINUTE = 60L
        private const val SECONDS_PER_HOUR = 3_600L
        private const val SECONDS_PER_DAY = 86_400L
    }
}
