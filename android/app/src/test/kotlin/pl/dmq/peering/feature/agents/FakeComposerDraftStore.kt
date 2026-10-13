package pl.dmq.peering.feature.agents

import pl.dmq.peering.session.agent.ComposerDrafts

class FakeComposerDraftStore(private var stored: ComposerDrafts = ComposerDrafts()) : ComposerDraftStore {
    var saves = 0
        private set

    override fun load(): ComposerDrafts = stored

    override fun save(drafts: ComposerDrafts) {
        stored = drafts
        saves++
    }

    fun current(): ComposerDrafts = stored
}
