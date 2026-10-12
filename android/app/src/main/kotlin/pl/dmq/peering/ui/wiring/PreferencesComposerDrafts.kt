package pl.dmq.peering.ui.wiring

import android.content.SharedPreferences
import pl.dmq.peering.feature.agents.ComposerDraftStore
import pl.dmq.peering.session.agent.ComposerDrafts

internal class PreferencesComposerDrafts(private val preferences: SharedPreferences) : ComposerDraftStore {
    override fun load(): ComposerDrafts = ComposerDraftCodec.decode(preferences.getString(KEY_DRAFTS, null))

    override fun save(drafts: ComposerDrafts) {
        preferences.edit().putString(KEY_DRAFTS, ComposerDraftCodec.encode(drafts)).apply()
    }

    private companion object {
        const val KEY_DRAFTS = "composer_drafts"
    }
}
