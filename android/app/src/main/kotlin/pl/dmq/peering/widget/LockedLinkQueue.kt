package pl.dmq.peering.widget

/** Holds the newest link that arrived while the app lock was showing, so it acts only after unlock. */
class LockedLinkQueue {
    private var held: WidgetLink? = null

    /** Returns [link] when it may act now, or null after holding it because [locked]. */
    fun admit(link: WidgetLink, locked: Boolean): WidgetLink? {
        if (!locked) return link
        held = link
        return null
    }

    /** The held link, handed out once. */
    fun release(): WidgetLink? = held.also { held = null }
}
