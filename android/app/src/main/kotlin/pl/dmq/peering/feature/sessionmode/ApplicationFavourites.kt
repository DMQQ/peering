package pl.dmq.peering.feature.sessionmode

import pl.dmq.peering.session.ports.KeyValueStore

/** The apps a person pinned for one computer, in the order they pinned them, kept per computer because each has its own apps. */
class ApplicationFavourites(private val store: KeyValueStore, hostId: String) {
    private val key = "application_favourites.$hostId"

    val bundleIdentifiers: List<String>
        get() = store.read(key)?.split(SEPARATOR)?.filter { it.isNotEmpty() }.orEmpty()

    operator fun contains(bundleIdentifier: String): Boolean = bundleIdentifier in bundleIdentifiers

    /** Adds it at the end, or takes it out if it is already there. */
    fun toggle(bundleIdentifier: String) {
        val list = bundleIdentifiers
        val next = if (bundleIdentifier in list) list - bundleIdentifier else list + bundleIdentifier
        store.write(key, next.joinToString(SEPARATOR))
    }

    private companion object {
        const val SEPARATOR = "\n"
    }
}

/**
 * A computer's apps in the three groups the apps sheet shows: pinned first, then running, then the rest installed. Each
 * app appears once, in the first group that claims it; a pinned app the computer no longer lists is skipped.
 */
data class ApplicationSections<App>(val favourites: List<App>, val running: List<App>, val installed: List<App>) {
    companion object {
        fun <App> of(favourites: List<String>, running: List<App>, installed: List<App>, bundleIdentifier: (App) -> String?): ApplicationSections<App> {
            val byBundle = HashMap<String, App>()
            for (app in installed + running) bundleIdentifier(app)?.let { byBundle[it] = app }
            val pinned = favourites.mapNotNull { byBundle[it] }
            val shown = favourites.filter { it in byBundle }.toMutableSet()
            val runningLeft = running.filter { app -> bundleIdentifier(app)?.let(shown::add) ?: true }
            val installedLeft = installed.filter { app -> bundleIdentifier(app)?.let(shown::add) ?: false }
            return ApplicationSections(pinned, runningLeft, installedLeft)
        }
    }
}
