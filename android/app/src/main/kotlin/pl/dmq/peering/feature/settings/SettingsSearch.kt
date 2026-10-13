package pl.dmq.peering.feature.settings

import androidx.annotation.StringRes
import pl.dmq.peering.R

/** The cards of the Settings tab, each with the words a search can find it by. */
enum class SettingsSection(@StringRes val keywordsRes: Int) {
    Device(R.string.settings_keywords_device),
    Controls(R.string.settings_keywords_controls),
    Quality(R.string.settings_keywords_quality),
    RemoteAccess(R.string.settings_keywords_remote),
    Background(R.string.settings_keywords_background),
    Invite(R.string.settings_keywords_invite),
    Security(R.string.settings_keywords_security),
    Trusted(R.string.settings_keywords_trusted),
    Identity(R.string.settings_keywords_identity),
    More(R.string.settings_keywords_more),
    Legal(R.string.settings_keywords_legal),
}

object SettingsSearch {
    /** Every word of [query] must appear in [keywords]. An empty query matches everything. */
    fun matches(keywords: String, query: String): Boolean {
        val words = query.lowercase().split(Regex("\\s+")).filter { it.isNotEmpty() }
        val haystack = keywords.lowercase()
        return words.all { it in haystack }
    }
}
