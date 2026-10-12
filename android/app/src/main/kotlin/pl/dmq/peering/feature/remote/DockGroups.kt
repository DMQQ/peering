package pl.dmq.peering.feature.remote

/** What a dock slot can hold, in the order the dock lists them. */
enum class DockControl {
    SOURCES, KEYS, CLIPBOARD, SHORTCUTS, TAB,
    LEFT, UP, DOWN, RIGHT, DELETE,
    ESCAPE, MODE, SETTINGS,
}

/** A run of dock buttons that belong together: either controls or key chords, never both. */
data class DockGroup(val id: String, val controls: List<DockControl>, val actions: List<QuickAction>) {
    val size: Int get() = controls.size + actions.size
}

object DockGroups {
    const val COLUMNS = 5
    const val APP_PREFIX = "app-"

    /** The controls, then the chords of the application on screen when it has a profile, then the edit chords. */
    fun of(profile: ApplicationProfile?, edits: List<QuickAction> = QuickActions.defaults): List<DockGroup> {
        val application = profile?.takeIf { it.actions.isNotEmpty() }?.let {
            DockGroup("$APP_PREFIX${it.bundleId}", emptyList(), it.actions.map(::asChord))
        }
        return listOfNotNull(
            DockGroup("controls", DockControl.entries, emptyList()),
            application,
            DockGroup("edits", emptyList(), edits).takeIf { edits.isNotEmpty() },
        )
    }

    private fun asChord(action: ApplicationAction) =
        QuickAction(action.id, action.title, action.label, action.keyCode, action.modifiers)
}
