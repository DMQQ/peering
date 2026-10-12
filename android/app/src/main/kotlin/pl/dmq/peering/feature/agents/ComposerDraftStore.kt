package pl.dmq.peering.feature.agents

import pl.dmq.peering.session.agent.ComposerDrafts

/** Keeps each chat's unsent draft across launches. Implementations must not throw into the presenter. */
interface ComposerDraftStore {
    fun load(): ComposerDrafts

    fun save(drafts: ComposerDrafts)
}
