package pl.dmq.peering.ui.wiring

import android.content.SharedPreferences
import pl.dmq.peering.feature.paywall.DailyRelayUsage
import pl.dmq.peering.feature.paywall.RelayUsageStore
import java.time.LocalDate

/** The day's relay use in preferences, as "yyyy-mm-dd;seconds". A value that does not parse counts as no use. */
internal class PreferencesRelayUsageStore(private val preferences: SharedPreferences) : RelayUsageStore {
    override fun load(): DailyRelayUsage? {
        val stored = preferences.getString(KEY_USAGE, null) ?: return null
        val parts = stored.split(SEPARATOR)
        if (parts.size != 2) return null
        val day = runCatching { LocalDate.parse(parts[0]) }.getOrNull() ?: return null
        val seconds = parts[1].toLongOrNull() ?: return null
        return DailyRelayUsage(day, seconds)
    }

    override fun save(usage: DailyRelayUsage) {
        preferences.edit().putString(KEY_USAGE, "${usage.day}$SEPARATOR${usage.seconds}").apply()
    }

    private companion object {
        const val KEY_USAGE = "relay_usage"
        const val SEPARATOR = ";"
    }
}
