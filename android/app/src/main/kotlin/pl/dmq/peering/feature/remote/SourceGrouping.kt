package pl.dmq.peering.feature.remote

import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import pl.dmq.peering.wire.CaptureCatalog
import pl.dmq.peering.wire.CaptureSourceDescriptor

/** An application with the windows it has open. Selecting the heading captures the whole application when it is [application]. */
data class ApplicationGroup(
    val id: String,
    /** Null when the catalogue does not list the owning application as capturable: only the whole-application pick is lost. */
    val application: CaptureSourceDescriptor?,
    val title: String,
    val iconData: String?,
    val windows: List<CaptureSourceDescriptor>,
) {
    val bundleIdentifier: String? get() = application?.bundleIdentifier ?: windows.firstNotNullOfOrNull { it.bundleIdentifier }

    fun narrowing(to: List<CaptureSourceDescriptor>): ApplicationGroup = copy(windows = to)
}

/** An application the computer has installed but is not running. Choosing one opens it there. */
data class InstalledApplication(val bundleIdentifier: String, val title: String, val iconData: String?)

object SourceGrouping {
    /**
     * Driven by the windows: a group exists because something is in it, and every window offered is accounted for. The
     * order is the catalogue's. A window joins the application with the same bundle identifier, or the same name when it
     * has none, which is how the computer groups them too.
     */
    fun applicationGroups(applications: List<CaptureSourceDescriptor>, windows: List<CaptureSourceDescriptor>): List<ApplicationGroup> {
        val byKey = LinkedHashMap<String, CaptureSourceDescriptor>()
        for (application in applications) byKey.putIfAbsent(key(application.bundleIdentifier, application.title), application)
        val grouped = LinkedHashMap<String, MutableList<CaptureSourceDescriptor>>()
        for (window in windows) grouped.getOrPut(key(window.bundleIdentifier, window.subtitle)) { mutableListOf() }.add(window)
        return grouped.map { (key, owned) ->
            val application = byKey[key]
            ApplicationGroup(
                id = application?.id ?: "group:$key",
                application = application,
                title = application?.title ?: owned.first().subtitle ?: "",
                iconData = application?.iconPNGData ?: owned.first().iconPNGData,
                windows = owned,
            )
        }
    }

    /** A window match keeps its application's heading, and a heading match keeps every window: "Safari" asks about Safari. */
    fun filtered(groups: List<ApplicationGroup>, query: String): List<ApplicationGroup> {
        if (query.isBlank()) return groups
        return groups.mapNotNull { group ->
            if (group.title.contains(query, ignoreCase = true)) return@mapNotNull group
            val windows = group.windows.filter { matches(it, query) }
            if (windows.isEmpty()) null else group.narrowing(windows)
        }
    }

    fun matches(descriptor: CaptureSourceDescriptor, query: String): Boolean =
        query.isBlank() || descriptor.title.contains(query, ignoreCase = true) || descriptor.subtitle?.contains(query, ignoreCase = true) == true

    /** The bundle identifier, else the lowercased name, namespaced so an identifier equal to a name cannot merge unrelated groups. */
    private fun key(bundle: String?, name: String?): String =
        if (!bundle.isNullOrEmpty()) "b:$bundle" else "n:${name.orEmpty().lowercase()}"

    /** The installed applications not already running, from the catalogue's raw list. A row that cannot be read is skipped. */
    fun installedNotRunning(catalog: CaptureCatalog, query: String): List<InstalledApplication> {
        val running = (catalog.applications + catalog.windows).mapNotNull { it.bundleIdentifier }.toSet()
        return catalog.installedApplications.mapNotNull(::installed)
            .filter { it.bundleIdentifier !in running }
            .filter { query.isBlank() || it.title.contains(query, ignoreCase = true) }
    }

    private fun installed(element: JsonElement): InstalledApplication? {
        val row: JsonObject = (element as? JsonObject) ?: return null
        val bundle = row.string("bundleIdentifier") ?: return null
        val title = row.string("title") ?: return null
        return InstalledApplication(bundle, title, row.string("iconPNGData"))
    }

    private fun JsonObject.string(name: String): String? = (this[name] as? JsonPrimitive)?.contentOrNull
}
