package pl.dmq.peering.ui.kit

import android.content.res.Resources
import pl.dmq.peering.R
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.util.Locale
import kotlin.math.abs

private const val MINUTE = 60_000L
private const val HOUR = 60 * MINUTE
private const val DAY = 24 * HOUR

/** "5 minutes ago" or "in 2 hours", worded by the string resources so it follows the app's language. */
fun Resources.relativeTime(thenMillis: Long, nowMillis: Long = System.currentTimeMillis()): String {
    val diff = thenMillis - nowMillis
    val future = diff > 0
    val span = abs(diff)
    return when {
        span < MINUTE -> getString(R.string.time_just_now)
        span < HOUR -> count((span / MINUTE).toInt(), if (future) R.plurals.time_minutes_ahead else R.plurals.time_minutes_ago)
        span < DAY -> count((span / HOUR).toInt(), if (future) R.plurals.time_hours_ahead else R.plurals.time_hours_ago)
        else -> count((span / DAY).toInt(), if (future) R.plurals.time_days_ahead else R.plurals.time_days_ago)
    }
}

private fun Resources.count(value: Int, plural: Int): String = getQuantityString(plural, value, value)

/** A calendar date in the language and order of the app's current locale. */
fun localizedDate(millis: Long): String = format(millis, FormatStyle.MEDIUM, null)

fun localizedDateTime(millis: Long): String = format(millis, FormatStyle.MEDIUM, FormatStyle.SHORT)

private fun format(millis: Long, date: FormatStyle, time: FormatStyle?): String {
    val formatter = if (time == null) DateTimeFormatter.ofLocalizedDate(date) else DateTimeFormatter.ofLocalizedDateTime(date, time)
    return formatter.withLocale(Locale.getDefault()).format(Instant.ofEpochMilli(millis).atZone(ZoneId.systemDefault()))
}
