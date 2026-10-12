package pl.dmq.peering.ui.kit

import android.content.res.Resources
import pl.dmq.peering.R
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale
import kotlin.math.abs

private const val MINUTE = 60_000L
private const val HOUR = 60 * MINUTE
private const val DAY = 24 * HOUR

/** "5 minutes ago" or "in 2 hours", in the app's own wording: the system formatter follows the phone's language and mixes it into English screens. */
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

private val dateFormat = DateTimeFormatter.ofPattern("MMM d, yyyy", Locale.ENGLISH)
private val dateTimeFormat = DateTimeFormatter.ofPattern("MMM d, yyyy, HH:mm", Locale.ENGLISH)

/** A calendar date with English month names, to match the rest of the app's wording. */
fun englishDate(millis: Long): String = dateFormat.format(Instant.ofEpochMilli(millis).atZone(ZoneId.systemDefault()))

fun englishDateTime(millis: Long): String = dateTimeFormat.format(Instant.ofEpochMilli(millis).atZone(ZoneId.systemDefault()))
