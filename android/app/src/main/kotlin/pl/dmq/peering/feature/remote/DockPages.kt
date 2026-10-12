package pl.dmq.peering.feature.remote

/** What a dock slot can hold, in the order the pages fill. */
enum class DockControl {
    SOURCES, KEYS, CLIPBOARD, SHORTCUTS, TAB,
    LEFT, UP, DOWN, RIGHT, DELETE,
    ESCAPE, MODE, SETTINGS,
}

/** One page of the dock: either controls or key chords, never both. */
data class DockPage(val id: String, val controls: List<DockControl>, val actions: List<QuickAction>)

object DockPages {
    const val COLUMNS = 5
    const val EXPANDED_ROWS = 3

    /**
     * The pages for a dock that is [expanded] or not. The controls come first, then the chords. The application on
     * screen takes the second place, so the first page never moves and what the application offers is one swipe away.
     */
    fun of(expanded: Boolean, profile: ApplicationProfile?, edits: List<QuickAction> = QuickActions.defaults): List<DockPage> {
        val capacity = COLUMNS * if (expanded) EXPANDED_ROWS else 1
        val controls = DockControl.entries.chunked(capacity).mapIndexed { index, chunk ->
            DockPage("controls-$index", chunk, emptyList())
        }
        val editPages = edits.chunked(capacity).mapIndexed { index, chunk -> DockPage("edits-$index", emptyList(), chunk) }
        val first = controls.firstOrNull() ?: return editPages
        val application = profile?.let {
            it.actions.map(::asChord).chunked(capacity).mapIndexed { index, chunk ->
                DockPage("app-${it.bundleId}-$index", emptyList(), chunk)
            }
        }.orEmpty()
        return listOf(first) + application + controls.drop(1) + editPages
    }

    private fun asChord(action: ApplicationAction) =
        QuickAction(action.id, action.title, action.label, action.keyCode, action.modifiers)
}
