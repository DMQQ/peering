package pl.dmq.peering.session.agent

/** Each session keeps its own unsent draft, so moving between chats does not lose what was typed. */
data class ComposerDrafts(val bySession: Map<String, ComposerDraft> = emptyMap()) {
    fun draftFor(sessionID: String): ComposerDraft = bySession[sessionID] ?: ComposerDraft()

    fun withDraft(sessionID: String, draft: ComposerDraft): ComposerDrafts =
        if (draft.isEmpty) copy(bySession = bySession - sessionID) else copy(bySession = bySession + (sessionID to draft))
}
