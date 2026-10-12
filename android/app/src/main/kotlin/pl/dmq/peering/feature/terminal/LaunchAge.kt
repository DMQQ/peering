package pl.dmq.peering.feature.terminal

/** How long ago something happened, in the words the phone uses: "4 hours ago", "yesterday", "last week". */
sealed interface LaunchAge {
    data object JustNow : LaunchAge

    data class Minutes(val count: Int) : LaunchAge

    data class Hours(val count: Int) : LaunchAge

    data object Yesterday : LaunchAge

    data class Days(val count: Int) : LaunchAge

    data object LastWeek : LaunchAge

    data class Weeks(val count: Int) : LaunchAge

    data object LastMonth : LaunchAge

    data class Months(val count: Int) : LaunchAge

    companion object {
        fun between(nowMillis: Long, thenMillis: Long): LaunchAge {
            val seconds = ((nowMillis - thenMillis) / 1_000L).coerceAtLeast(0)
            val days = (seconds / DAY).toInt()
            return when {
                seconds < MINUTE -> JustNow
                seconds < HOUR -> Minutes((seconds / MINUTE).toInt())
                seconds < DAY -> Hours((seconds / HOUR).toInt())
                days < 2 -> Yesterday
                days < 7 -> Days(days)
                days < 14 -> LastWeek
                days < 30 -> Weeks(days / 7)
                days < 60 -> LastMonth
                else -> Months(days / 30)
            }
        }

        private const val MINUTE = 60L
        private const val HOUR = 3_600L
        private const val DAY = 86_400L
    }
}
