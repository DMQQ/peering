package pl.dmq.peering.feature.agents

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import pl.dmq.peering.session.agent.AgentSlash
import pl.dmq.peering.session.agent.DirectoryLister
import pl.dmq.peering.session.agent.FolderListing
import pl.dmq.peering.session.agent.MentionQuery
import pl.dmq.peering.session.agent.SlashSuggestion
import pl.dmq.peering.wire.RemoteDirectoryEntry

/** What the composer offers above the field while the draft is a slash command or ends in an @ mention. */
sealed interface ComposerHint {
    data object None : ComposerHint

    data class Slash(val items: List<SlashSuggestion>) : ComposerHint

    /** [matches] is every entry that fits; the screen shows the first few. */
    data class Mention(
        val query: MentionQuery,
        val matches: List<RemoteDirectoryEntry>,
        val loading: Boolean,
        val failure: String?,
    ) : ComposerHint
}

/** What the hints depend on besides the draft: which in-app commands the computer supports. */
data class HintOffers(val usage: Boolean, val model: Boolean)

/** Works out the hint for a draft, and asks the computer for the folders it needs. */
class ComposerHints(
    ui: StateFlow<ComposerUi>,
    private val lister: DirectoryLister,
    private val offers: HintOffers,
    scope: CoroutineScope,
) {
    val hint: StateFlow<ComposerHint> = combine(ui, lister.listings) { composer, listings -> derive(composer, listings) }
        .stateIn(scope, SharingStarted.Eagerly, ComposerHint.None)

    private fun derive(ui: ComposerUi, listings: Map<String, FolderListing>): ComposerHint {
        val agentId = ui.agentID ?: return ComposerHint.None
        if (ui.sessionID == null) return ComposerHint.None
        val slash = AgentSlash.query(ui.text)
        if (slash != null) {
            AgentSlash.folders(ui.directory, agentId).forEach(lister::request)
            val items = AgentSlash.suggestions(slash, agentId, ui.directory, offers.usage, offers.model) { listings[it]?.entries }
            return ComposerHint.Slash(items)
        }
        val mention = MentionQuery.of(ui.text) ?: return ComposerHint.None
        val folder = mention.folder(ui.directory)
        lister.request(folder)
        val listing = listings[folder]
        return ComposerHint.Mention(mention, mention.matches(listing?.entries), loading = listing == null, failure = listing?.failure)
    }
}
